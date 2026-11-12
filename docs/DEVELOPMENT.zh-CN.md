[← 返回项目首页](../README.md) · [English overview](../README.en.md)

# Plinth for Mac

（原名 FitHair；Swift 模块和源码目录仍叫 FitHair，只有用户看得到的名字换了。）

上传一张正脸自拍 → 在本机用 Apple Vision 找面部关键点、量额头 / 颧骨 / 下颌宽度和脸长 → 判断七种脸型 → 从对应的发型池推荐发型 → 生成给理发师看的卡片。

## 运行

```bash
swift run                 # 开发时直接运行
./scripts/build-app.sh    # 打包成 build/Plinth.app（带图标和摄像头权限说明）
./scripts/build-dmg.sh    # 再做成 build/Plinth.dmg（约 25 MB），拖到“应用程序”安装
./scripts/build-dmg.sh --with-model   # 或者把写实试戴的模型也装进去：build/Plinth-with-model.dmg（约 2 GB），装上就能用
open build/Plinth.app
swift test -c release     # 完整测试（图像处理在 release 下更快）
```

也可以双击 `Package.swift` 用 Xcode 打开。

测试用：`open build/Plinth.app --args -analyze /path/to/photo.jpg` 会直接分析这张照片。

## 结构

| 路径 | 内容 |
|---|---|
| `Sources/FitHair/Analysis/FaceAnalyzer.swift` | Vision 关键点 → 四项测量（F / C / J / L、下颌角） |
| `Sources/FitHair/Analysis/HairSegmenter.swift` | 头发 / 脸部皮肤分割（Core ML），用来量发际线和额头两侧 |
| `Sources/FitHair/Analysis/FaceShapeClassifier.swift` | 和七种脸型的典型比例比较，输出各脸型占比 |
| `Sources/FitHair/Model/` | 七种脸型、发型模型（从 `Resources/hairstyles.json` 读取）、理发师参数 |
| `Sources/FitHair/Model/HairPreferences.swift` | 用户填写的发量、发丝、天生卷度和每日打理时间，以及发型的打理标签 |
| `Sources/FitHair/Resources/hairstyles.json` | 发型库：每种性别 12 款，每款带七种脸型的适合度、理发师参数和生图提示词 |
| `scripts/hairstyle-prompts.py` | 打印还没有石膏像图的发型的完整提示词 |
| `Sources/FitHair/Analysis/HairTryOn.swift` | 本地试戴：把发型石膏像按脸部轮廓变形，取下头发、上色，贴到照片上 |
| `Sources/FitHair/Analysis/HairRepaint.swift` | 写实试戴：贴图只当发型的草图，用本机的图像模型（Core ML）把头发连同发际线、鬓角按这个人的头重新画；模型没装时不启用 |
| `Sources/FitHair/Analysis/ClipTokenizer.swift` | 图像模型文字编码器用的分词器 |
| `Sources/FitHair/Analysis/TryOnRenderer.swift` | 按照片、发型、发色区分试戴结果，丢弃过期任务，最多缓存 6 张；装了写实模型时贴图不上屏，只交出重画好的成品（重画失败才退回贴图） |
| `Sources/FitHair/Analysis/RepaintModelDownload.swift` | 写实试戴的模型首次使用时下载：一个 zip，续传、校验 SHA-256、解压、检查后一次性装好；试戴页上的下载状态也在这里 |
| `scripts/pack-model.sh` | 把装好的模型打成供下载的 `build/RepaintModel.zip`，打印要填进 Info.plist 的校验值 |
| `scripts/repaint-proto.py` | 写实试戴的 Python 原型，各项参数是在它上面试出来的，理由写在文件开头 |
| `Sources/FitHair/Camera/CaptureSession.swift` | 可取消的倒计时和连拍任务，退出拍照页或选择照片时取消 |
| `Sources/FitHair/Analysis/ColourAdvisor.swift` | 从照片读肤色冷暖和现有发色，给发色建议和漂发说明（经验规则，受光线影响） |
| `Sources/FitHair/Support/HairWord.swift` | 首页的发丝字：沿笔画走向生成发丝，烘焙成开屏动画和最终字样 |
| `Sources/FitHair/Views/` | 首页、拍照、测量、结果、发型池、试戴、理发师卡片 |
| `Sources/FitHair/Resources/` | 首页变形视频、脸型白模、发型白模（每款正面 `hair-<id>.jpg`、侧面 `-side`、背面 `-back`）、`HairSegmenter.mlmodelc` |
| `scripts/convert-hair-model.py` | 把 MediaPipe 的 .tflite 模型转成 Core ML |
| `assets/AppIcon/` | 图标源文件和 .icns |
| `docs/prompts/` | 生成发型石膏像用的提示词 |
| `docs/reference/` | 设计时的参考图 |
| `archive/` | 交付过的素材备份，App 不使用 |

## 还没做 / 需要校准

- 脸型判断的典型比例已经按七张参考石膏像校准过（三成教材比例、七成实测，见 `FaceShape.prototype` 的注释），七张石膏像都能判成自己（`ClassifierTests.testBustsClassifyAsThemselves`）。但石膏像里鹅蛋 / 菱形、方 / 三角两对在镜头里几乎一样，判断置信度不高；仍需要用人工标注的真人自拍校准。
- 第二名的分数达到第一名的 45% 时算没有定论：页面写“偏某某脸”，按最接近的 2–3 种一起推荐，发型要同时适合这几种才算推荐；只有拍摄条件不足时才写「脸型待确认」。手动确认后按选定的脸型推荐。这个阈值是在满足重复性测试（带噪声的参考图不能给出确定的错误脸型）前提下的最低值，只在石膏像上定过，不代表真人识别准确率已经验证。
- 这些情况不下结论、提示重拍：脸太小（颧骨宽不足 100 像素）、脸被画面裁掉、头歪超过 20°、多张脸；照片倒置直接报错。
- 发际线和额头两侧用头发分割来量；刘海挡住额头时退回按比例估算，并提示用户。
- 发型库 24 款都有石膏像图。f12、m6–m12 的构图比其余的近（头更大、肩膀少）。
- 发型页默认只显示适合度 ≥ 80 的前 6 款（不足 3 款时补到 3 款并提示是较接近的备选），切到「全部」看所有。发量、发丝和天生卷度来自用户填写，按明确的经验规则调整排序；打理时间按发型库标注筛选，不会为了凑数量越过时间上限。实际发质、烫染史和所需造型时间仍需到店确认。
- 最近一次的照片和测量结果保存在本机（`~/Library/Application Support/Plinth/LastResult`），首页可以接着看，也可以删除；发型详情可切换正面、侧面、背面。
- 菜单栏：运行时有状态栏图标，面板里是当前发型、修剪时间（“今天剪了”记录，可开到期提醒）、隔空投送和复制文字，把照片拖到图标上直接分析。记录过剪发后，关窗不退出、留在菜单栏，并释放开屏素材。
- 理发师卡片：窗口里是一屏放下的横版，单款并排显示正面、侧面、背面（三张齐全时），按头发宽度自动取景；隔空投送和存图导出手机版（放大字号，一屏看完）；打印用桌面版；收藏 2 款以上可合成一张（最多 6 款）。「现在长度」「烫染过吗」只写在卡片上，不影响推荐。
- 收藏独立于单次分析保存，⌘N 开始新分析时会保留。收藏或筛选为空时显示空状态，不再保留上一款的详情。
- 试戴分两步。先是本地贴图（`HairTryOn`）：石膏像朝向不一（有的朝左有的朝右，偏转量也不同），贴之前按鼻尖相对两眼的偏移量出人和石膏像各自朝哪边，把头发相对五官平移到对应位置，方向相反且差得多时改用石膏像的镜像（分缝会跟着换边）。然后是写实重画（`HairRepaint`，见下面「写实试戴的模型」）：贴上去的石膏像头发只是草图，模型在它的轮廓里重新长出头发，和头发挨着的皮肤（额头、两鬓、耳前，28 像素宽）一起重画，所以发际线、鬓角、渐变推剪的两侧是按这个人的头画的；眉毛到嘴之间不动，是照片原样。重画强度是 12 步里走 7 步：走 6 步出来还是石膏像那块头发换了质感，像假发；走 8 步以上发型会走样（中分画成齐刘海），颜色也跟着提示词跑。要让画出来的像石膏像那一款，靠两样：草稿里石膏像发束的明暗画得比看着合适的重得多（约 2.7 倍，高光只加到 1.6 倍，否则会画出白色发条），这样发束的位置和走向才扛得住重画开始时加的噪声（只加重发束本身的起伏，不放大石膏像整体的单侧打光，否则背光的半边会成一片黑、纹理全丢）；石膏像的眉毛比真人低，贴之前把它的眉毛对到人的眉毛上，刘海才不会盖到眉毛；发型的英文描述要和石膏像一致，个别石膏像和 `prompt` 对不上（飞机头 `prompt` 只写“向上向后梳”，画出来是光滑油头，石膏像是一束束分开的粗发束；写成 spiky 又会画成针一样的刺；纹理烫写 perm、tousled 会画成炸开的小卷，石膏像是中分的松散大波浪）的在 `hairstyles.json` 里另写一条 `look`，试戴用 `look`。带渐变的发型（描述里写了 fade 的男士款）两侧不按满头发上色：石膏像两侧是推短的平面，整块上色会画成一块发色，染发时最明显；现在按渐变高度（高 / 中 / 低）让头皮透出来，越靠近耳朵头发越少。模型是把整个头缩到 512 像素画的，头发通常比照片糊，画完后把重画的区域锐化到和照片一样清楚（照片本身糊就反过来模糊一点）；试过把头发分四块放大再画一遍，画出来的是更大更平滑的发束，不是更细的发丝，没有采用。新头发可以画到照片边缘以外的补出来的背景上，不会在照片边上被切平。在 12 张真人照片上肉眼看过，没有量化指标。旧头发的清理有三层：分割模型认不出的碎发、翘起的发梢按颜色从头发边上找出来一起擦掉；新发型盖不到的地方一律单独重画一遍（交给画头发那一遍，远看可以，放大是一团脏色）；重画后再用分割模型查一次，原来该空着的地方还有头发就换个起点再清，最多两次。刘海摘掉后留在额头上的发梢和阴影也按颜色找（从脸颊肤色偏向发色、又连着头发的额头皮肤），刘海下方 36 像素内的额头整片重画，否则细发丝之间夹着的原皮肤会留成一道道细线。已知问题：法式碎刘海（m7）石膏像是一片片很细的短碎发，这种细纹理重画时留不住，画出来是偏顺的短发，换描述、减轻重画都试过，没解决；发丝的卷度、分缝位置会和石膏像有出入，同一款在不同人头上不完全一样；被头发挡住的衣服和背景是模型补的，会和原来不一样，偶尔多出耳环；横在脸上的旧发丝在不动的区域里，擦不掉；头发和背景颜色接近时碎发找不出来；头转得多或低头抬头时只做了平移，发丝走向仍是石膏像那个角度的。
- 寸头 m3、m11 和长直发 f12 现在直接展示示意图和卡片入口。切换发型或发色时，新图生成期间继续显示同一张照片的上一张成品（第一次是原照片），但只有对应的试戴图能保存。装了写实模型时贴图草稿不给用户看：等待时底图虚化，上面盖一层扫光，底部文字跟着实际进度变（准备、清理原来的头发、画出发丝、精修细节），画好后直接换成成品；系统开了“减弱动态效果”时不扫光。
- 换脸型用的是固定的七张参考石膏像。
- 只有浅色外观。

## 加一款发型

1. 在 `Sources/FitHair/Resources/hairstyles.json` 加一条记录：`id`（女 f、男 m 开头）、名字、长度、打理信息、三条 `why`、一句 `say`、六条 `specs`（对应 `specLabels`）、两条 `avoid`、七种脸型的 `scores`（0–100，≥ 80 算推荐）、英文 `prompt`。石膏像做出来和 `prompt` 有出入时再加一条 `look`，照着石膏像写，试戴按它画。另填 `hairProfile`：`minutes`（与 `care` 一致）、`finish`（cropped / straight / wavy / curly）、`layers`（minimal / light / high）、`addsVolume`、`keepsWeight` 和 `supportsTryOn`。后一个字段应以实际试戴验证结果为准。
2. `python3 scripts/hairstyle-prompts.py <id>` 拿到完整提示词，生成 4:5 的石膏像图，存成 `hair-<id>.jpg`；再按同样的石膏像和发型做侧面、背面，存成 `hair-<id>-side.jpg`、`hair-<id>-back.jpg`，都是 640×800。
3. `swift test`：`LibraryTests` 会检查字段齐全，并要求七种脸型的第一名至少有五款不同。

## 写实试戴的模型

`HairRepaint` 从 `~/Library/Application Support/Plinth/RepaintModel/` 读模型，目录里要有 `TextEncoder.mlmodelc`、`Unet.mlmodelc`、`VAEEncoder.mlmodelc`、`VAEDecoder.mlmodelc`、`vocab.json`、`merges.txt`，共约 2 GB。用 `build-dmg.sh --with-model` 打的安装包把这个目录放在 App 里面（`Plinth.app/Contents/Resources/RepaintModel`，连同许可证全文 `LICENSE.txt` 和一份写明模型来源的 `NOTICE.txt`，两者的原件在 `Support/RepaintModel-LICENSE.txt`、`Support/RepaintModel-NOTICE.txt`），App 先找里面这份，是完整的就用它，否则才看上面的目录。两处都没有时试戴页只显示贴图示意。

带模型的安装包适合放网盘（百度网盘这类没有直链的地方只能这样发）：一个文件，装上就能用，代价是每出一版都要重新下 2 GB。小安装包配合下面的首次下载，App 更新只有 25 MB，但模型压缩包要放在有直链的地方。

### 首次使用时下载

小安装包里没有模型。App 里配置了下载地址时，试戴页右侧面板顶部会出现“下载写实效果”：点了才下（约 2 GB，一个 zip），带进度、可暂停，断了或暂停后接着下；下完先核对整个压缩包的 SHA-256，对不上就删掉、不解压；再解压、检查里面该有的文件齐全且没有夹带链接，最后一次性放到上面的目录。装好后试戴页自动换成写实效果。下载期间要多占约 2 GB 磁盘（压缩包和解压出来的各一份），装好后压缩包自动删除。实现在 `RepaintModelDownload.swift`。

发布步骤：

```bash
./scripts/pack-model.sh        # 把本机装好的模型打成 build/RepaintModel.zip，并打印它的 SHA-256
```

把 `build/RepaintModel.zip` 传到任何能用 https 固定地址直接下载的地方（最好支持断点续传，即 HTTP Range），然后在 `Support/Info.plist` 里填两项再重新打包：`PlinthRepaintModelURL`（压缩包的完整地址）和 `PlinthRepaintModelSHA256`（脚本打印的那一串）。两项都留空时 App 不提供下载。只接受 https，而且必须填校验值：换了压缩包就必须重新出一版 App。模型的许可证（CreativeML OpenRAIL-M）要随模型一起分发：脚本会把 `Support/` 里的许可证全文和来源说明一起打进压缩包。

发布前在本机试一遍，不用碰已装好的模型：起一个本地服务器，用环境变量让 App 从它下载到别的目录。

```bash
python3 -m http.server 8765 --bind 127.0.0.1 --directory build
open build/Plinth.app --env PLINTH_MODEL_URL=http://127.0.0.1:8765/RepaintModel.zip \
  --env PLINTH_MODEL_SHA256=<校验值> --env PLINTH_MODEL_DIR=/tmp/RepaintModel-trial
```

（`python3 -m http.server` 不支持断点续传，试续传要换一个支持 Range 的服务器。）

### 模型的来历

模型是 [Lykon/dreamshaper-8-inpainting](https://huggingface.co/Lykon/dreamshaper-8-inpainting)（Stable Diffusion 1.5 重绘，CreativeML OpenRAIL-M 许可，分发时要附许可并遵守其使用限制），用 Apple 的 [ml-stable-diffusion](https://github.com/apple/ml-stable-diffusion) 转成 Core ML。转换工具需要 Python 3.11（coremltools 没有 3.14 的安装包），scipy 要 1.16 以上才能在 macOS 27 上加载：

```bash
python -m python_coreml_stable_diffusion.torch2coreml --model-version <模型目录> \
  --convert-vae-encoder --convert-vae-decoder --convert-unet --convert-text-encoder \
  --unet-batch-one --attention-implementation ORIGINAL --compute-unit CPU_AND_GPU -o out
xcrun coremlcompiler compile out/<…>_unet.mlpackage RepaintModel/   # 四个模型各编一次，改成上面的名字
```

`--unet-batch-one` 不能省：后半程不带引导的步骤只跑一次 U-Net。`vocab.json`、`merges.txt` 取自模型的 `tokenizer/`。

在 M5 / 16 GB 上，一款发型的第一张约 5–8 秒（清场和画头发各一遍；新发型把旧头发全盖住时只要约 3 秒），旧长发要再清的话每多一次约 3 秒，见过最长 18 秒。同一张照片同一款发型换颜色约 2 秒：清场的结果按“照片 + 发型”留着（最多 3 组），换色只重画头发。模型加载约 2–3 秒，进发型列表页时就开始加载，所以进试戴页不用等这一段；模型在最后一次使用 3 分钟后自动释放（约 2 GB 内存），不再是一离开试戴页就卸载。

`REPAINT_TIME=<照片>` 跑 `testRepaintWaits` 可以量这几段等待。`swift test` 里和它有关的几项默认跳过，要设环境变量：`REPAINT_OUT` + `REPAINT_PHOTOS`（照片目录）+ `REPAINT_STYLES` 导出草稿和蒙版，加 `REPAINT_RUN=1` 用装好的模型重画；`CLIP_REFERENCE` 指向参考分词结果时核对分词器。

## 头发分割模型

`HairSegmenter.mlmodelc` 由 Google MediaPipe 的 `selfie_multiclass_256x256.tflite`（Apache License 2.0）转换而来，
输出背景、头发、身体皮肤、脸部皮肤、衣服、其他六类。许可证全文在 `Resources/HairSegmenter-LICENSE-Apache-2.0.txt`。重新生成：

```bash
curl -LO https://storage.googleapis.com/mediapipe-models/image_segmenter/selfie_multiclass_256x256/float32/latest/selfie_multiclass_256x256.tflite
pip install tflite coremltools numpy
python scripts/convert-hair-model.py selfie_multiclass_256x256.tflite HairSegmenter.mlmodel
xcrun coremlcompiler compile HairSegmenter.mlmodel Sources/FitHair/Resources/
```

转换后和原版逐像素比对，四个石膏像上 99.9% 的像素分类一致。发布前要按 Apache 2.0 附上许可证全文。
