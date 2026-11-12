"""Usage: python convert-hair-model.py selfie_multiclass_256x256.tflite HairSegmenter.mlmodel

Direct TFLite → Core ML (neuralnetwork) converter for the MediaPipe multiclass selfie model.
Activations from conv-like ops are kept NCHW; layout-sensitive ops run in TFLite's native NHWC."""
import sys, numpy as np, tflite
import coremltools as ct
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.mil import types

src, dst = sys.argv[1], sys.argv[2]
buf = open(src, 'rb').read()
M = tflite.Model.GetRootAsModel(buf, 0)
G = M.Subgraphs(0)
OPN = {v: k for k, v in tflite.BuiltinOperator.__dict__.items() if not k.startswith('_')}

def const(i):
    t = G.Tensors(i)
    data = M.Buffers(t.Buffer()).DataAsNumpy()
    if isinstance(data, int) or data is None or len(data) == 0:
        return None
    dt = {0: np.float32, 2: np.int32, 4: np.int64}[t.Type()]
    return np.frombuffer(data.tobytes(), dtype=dt).reshape(t.ShapeAsNumpy() if t.ShapeLength() else ())

def opts(op, cls):
    o = cls(); tb = op.BuiltinOptions(); o.Init(tb.Bytes, tb.Pos); return o

def act(x, f):
    if f == 0: return x
    if f == 1: return mb.relu(x=x)
    if f == 3: return mb.clip(x=x, alpha=0.0, beta=6.0)
    raise ValueError(f"activation {f}")

in_idx, out_idx = G.Inputs(0), G.Outputs(0)
H, W = G.Tensors(in_idx).ShapeAsNumpy()[1:3]

@mb.program(input_specs=[mb.TensorSpec(shape=(1, 3, int(H), int(W)))])
def prog(image):
    env = {in_idx: (image, 'nchw')}

    def get(i, want):
        c = const(i)
        if c is not None:
            if want == 'nchw' and c.ndim == 4: c = c.transpose(0, 3, 1, 2)
            return c
        v, lay = env[i]
        if len(v.shape) != 4 or lay == want: return v
        return mb.transpose(x=v, perm=[0, 3, 1, 2] if want == 'nchw' else [0, 2, 3, 1])

    def bcast_const(c, lay):
        c = c.astype(np.float32)
        if c.ndim == 0 or c.size == 1: return c.reshape(())
        c4 = c.reshape((1,) * (4 - c.ndim) + c.shape)
        return c4.transpose(0, 3, 1, 2) if lay == 'nchw' else c4

    for n in range(G.OperatorsLength()):
        op = G.Operators(n)
        oc = M.OperatorCodes(op.OpcodeIndex())
        name = OPN[max(oc.BuiltinCode(), oc.DeprecatedBuiltinCode())]
        ins = [op.Inputs(k) for k in range(op.InputsLength())]
        out = op.Outputs(0)

        if name == 'CONV_2D':
            o = opts(op, tflite.Conv2DOptions)
            w = const(ins[1]).transpose(0, 3, 1, 2)
            b = const(ins[2]) if len(ins) > 2 and ins[2] >= 0 else None
            y = mb.conv(x=get(ins[0], 'nchw'), weight=w, bias=b, strides=[o.StrideH(), o.StrideW()],
                        pad_type='same' if o.Padding() == 0 else 'valid',
                        dilations=[o.DilationHFactor(), o.DilationWFactor()])
            env[out] = (act(y, o.FusedActivationFunction()), 'nchw')
        elif name == 'DEPTHWISE_CONV_2D':
            o = opts(op, tflite.DepthwiseConv2DOptions)
            w = const(ins[1])                      # [1, kh, kw, C*m]
            cout = w.shape[3]
            x = get(ins[0], 'nchw'); cin = x.shape[1]
            w = w.transpose(3, 0, 1, 2)            # [C*m, 1, kh, kw]
            b = const(ins[2]) if len(ins) > 2 and ins[2] >= 0 else None
            y = mb.conv(x=x, weight=w, bias=b, strides=[o.StrideH(), o.StrideW()], groups=cin,
                        pad_type='same' if o.Padding() == 0 else 'valid',
                        dilations=[o.DilationHFactor(), o.DilationWFactor()])
            env[out] = (act(y, o.FusedActivationFunction()), 'nchw')
        elif name in ('ADD', 'MUL'):
            o = opts(op, tflite.AddOptions if name == 'ADD' else tflite.MulOptions)
            ca, cb = const(ins[0]), const(ins[1])
            if ca is None and cb is None:
                la, lb = env[ins[0]][1], env[ins[1]][1]
                lay = la if la == lb else 'nhwc'
                a, b = get(ins[0], lay), get(ins[1], lay)
            else:
                vi = ins[0] if ca is None else ins[1]
                lay = env[vi][1] if len(env[vi][0].shape) == 4 else 'nhwc'
                a = get(vi, lay)
                b = bcast_const(cb if ca is None else ca, lay) if len(env[vi][0].shape) == 4 else (cb if ca is None else ca).astype(np.float32)
            y = mb.add(x=a, y=b) if name == 'ADD' else mb.mul(x=a, y=b)
            env[out] = (act(y, o.FusedActivationFunction()), lay)
        elif name == 'RESHAPE':
            shape = list(G.Tensors(out).ShapeAsNumpy())
            env[out] = (mb.reshape(x=get(ins[0], 'nhwc'), shape=shape), 'nhwc')
        elif name == 'TRANSPOSE':
            env[out] = (mb.transpose(x=get(ins[0], 'nhwc'), perm=list(const(ins[1]))), 'nhwc')
        elif name == 'SUM':
            o = opts(op, tflite.ReducerOptions)
            env[out] = (mb.reduce_sum(x=get(ins[0], 'nhwc'), axes=list(np.atleast_1d(const(ins[1]))), keep_dims=bool(o.KeepDims())), 'nhwc')
        elif name == 'SOFTMAX':
            o = opts(op, tflite.SoftmaxOptions)
            x = get(ins[0], 'nhwc')
            if o.Beta() != 1.0: x = mb.mul(x=x, y=np.float32(o.Beta()))
            env[out] = (mb.softmax(x=x, axis=-1), 'nhwc')
        elif name == 'RESIZE_BILINEAR':
            o = opts(op, tflite.ResizeBilinearOptions)
            h, w = [int(v) for v in const(ins[1])]
            x = get(ins[0], 'nchw')
            assert h % x.shape[2] == 0 and w % x.shape[3] == 0, (h, w, x.shape)
            assert o.HalfPixelCenters() and not o.AlignCorners(), 'only half-pixel bilinear handled'
            print('bilinear', x.shape, '->', h, w)
            # NN 'upsample' with align_corners=False is the half-pixel-centre definition
            env[out] = (mb.upsample_bilinear(x=x, scale_factor_height=float(h // x.shape[2]), scale_factor_width=float(w // x.shape[3]), align_corners=False), 'nchw')
        elif name == 'RESIZE_NEAREST_NEIGHBOR':
            x = get(ins[0], 'nchw')
            h, w = [int(v) for v in const(ins[1])]
            env[out] = (mb.upsample_nearest_neighbor(x=x, scale_factor_height=h // x.shape[2], scale_factor_width=w // x.shape[3]), 'nchw')
        elif name == 'TRANSPOSE_CONV':
            o = opts(op, tflite.TransposeConvOptions)
            oshape = [int(v) for v in const(ins[0])]          # NHWC
            w = const(ins[1]).transpose(3, 0, 1, 2)           # [O,kh,kw,I] -> [I,O,kh,kw]
            b = const(ins[3]) if len(ins) > 3 and ins[3] >= 0 else None
            y = mb.conv_transpose(x=get(ins[2], 'nchw'), weight=w, bias=b, strides=[o.StrideH(), o.StrideW()],
                                  pad_type='same' if o.Padding() == 0 else 'valid',
                                  output_shape=[oshape[0], oshape[3], oshape[1], oshape[2]])
            env[out] = (y, 'nchw')
        else:
            raise NotImplementedError(name)

    return mb.identity(x=get(out_idx, 'nchw'), name='segmentation')

model = ct.convert(prog, convert_to='neuralnetwork', minimum_deployment_target=ct.target.macOS11)
spec = model.get_spec()
spec.description.metadata.shortDescription = 'MediaPipe multiclass selfie segmentation (Apache-2.0, Google). Input: RGB 256x256 NCHW normalised to [-1,1]. Output: logits [1,6,256,256] for background, hair, body-skin, face-skin, clothes, others.'
spec.description.metadata.license = 'Apache-2.0'
ct.utils.save_spec(spec, dst)
print('saved', dst)
