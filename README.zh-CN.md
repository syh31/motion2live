# motion2live

[English](<README.md>) | 简体中文

把安卓手机的 **Motion Photo（动态照片）** 转成供苹果「照片」导入的
**Live Photo 图片 + 视频文件对**。

面向三星、Google、OPPO 等设备使用的常见“静态图片容器 + 尾部视频”布局，
不代表所有品牌、机型和系统版本都已验证。当前是 macOS 命令行工具，没有图形界面。

## 功能与环境要求

- 拆分 JPEG（包括 Ultra HDR JPEG）及 HEIC/HEIF Motion Photo；
- 根据 XMP 长度信息或 ISO-BMFF 容器扫描定位尾部 MP4/MOV；
- 通过 ImageIO 将静态图编码为 HEIC 或 JPEG，并写入 Apple MakerNote 配对标识；
- 尝试将源 HDR 静态图转为带 ISO 增益图的图片；
- 使用 AVFoundation passthrough 重封装视频，不重新压缩视频；
- 校验图片解码和配对元数据，报告 HDR 信息；可选用 Photos API 实际导入测试。

**完整流程依赖 macOS**：图片、视频和验证工具使用 ImageIO、AVFoundation、Photos
等 Apple 框架，不能直接在 Linux、Windows 或普通 Linux Docker 容器中运行。
纯 Python 拆分器可以独立使用，不依赖这些框架。

构建与运行需要：

- 建议使用 macOS 15 或更高版本，以及支持源码所用 API 的近期 Xcode Command Line Tools / SDK。
  当前代码直接引用较新的 HDR 和 AVFoundation API，没有旧系统兼容分支；
  `--hdr sdr` 不等于能够在旧 macOS 上构建或运行。最低可用系统与 SDK 组合尚未系统验证。
- 建议 Python 3.10+；Python 脚本只使用标准库，无需 `pip install`。
- `swiftc` 编译器。尚未安装 Apple 命令行工具时，可执行 `xcode-select --install`。

仓库不包含编译产物或私人测试素材；获取源码后需要自行构建。
历史样本说明记录过 Photos 配对成功，但当前仓库没有完整的跨设备、跨系统兼容性测试矩阵。

## 一键转换

在项目根目录执行：

```bash
bash build.sh

python3 tools/motion2live.py /path/to/MOTION_PHOTO.jpg /path/to/output/IMG_LIVE \
  --hdr preserve
```

输出两个具有相同基名的文件：

```text
IMG_LIVE.HEIC
IMG_LIVE.MOV
```

建议将两个文件一起导入 macOS「照片」，并保留相同基名。
配对依赖文件内部的标识，不是单纯把文件改成同名就能成为 Live Photo。
导入后确认显示为 Live Photo 且能够播放；如需传到 iPhone，优先从「照片」中分享已识别的
Live Photo。直接 AirDrop 两个原始文件是否能自动配对取决于接收端及导入路径，不作保证。

### HDR 模式

```text
--hdr auto       源图被识别为 HDR 时尝试输出 HDR，失败时警告并尝试降级 SDR（默认）
--hdr preserve   源图被识别为 HDR 时要求输出 headroom > 1.01，否则转换失败
--hdr sdr        使用 SDR 解码和编码路径
```

`preserve` 不会把 SDR 输入升级成 HDR，也不是像素或增益图无损保留保证。
源 HDR 检测依赖 ImageIO 报告的 headroom 或增益图；无法识别的 HDR 输入可能被当成 SDR。
如果在意 HDR，建议使用 `--hdr preserve`，并检查日志和实际显示效果。

静态图默认输出 HEIC，也可以输出 JPEG（扩展名为 `.JPG`）：

```bash
python3 tools/motion2live.py input.jpg IMG_LIVE --still-format jpeg --hdr preserve
```

### 一键入口参数

| 参数 | 说明 |
|---|---|
| `src` | 输入的单个 Motion Photo 文件 |
| `out` | 输出基路径，建议使用不含扩展名、不含额外点号的基名，例如 `output/IMG_LIVE` |
| `--still-format heic\|jpeg` | 静态图格式，默认 `heic` |
| `--hdr auto\|preserve\|sdr` | HDR 策略，默认 `auto` |
| `--uuid ID` | 自定义配对标识，默认生成随机 UUID；输入会转成大写，但不校验 UUID 格式 |
| `--date ISO8601` | 覆盖视频日期，例如 `2026-09-11T02:45:51Z`；不修改图片 EXIF 日期 |
| `--primary N` | 手动指定视频起始字节偏移，仍需通过 MP4/QuickTime 边界检查 |
| `--video-length N` | 提供尾部视频长度提示；不是视频裁剪参数 |
| `--force` | 允许替换已有输出 |
| `--no-validate` | 跳过末尾的结构与配对校验，不跳过图片编码工具自身的检查 |

查看帮助：

```bash
python3 tools/motion2live.py --help
python3 tools/make_livephoto_still.py --help
```

默认拒绝覆盖任一已有输出。转换先在输出目录下的临时目录中进行，完成后依次替换两个
目标文件；两个文件的发布不是整体原子事务。不要让输出路径与源文件重合，也不要并发写入
同一输出基名。当前一次处理一个输入，不提供批量目录模式。

## 自动提取的工作方式

[拆分器](<tools/make_livephoto_still.py>) 的处理顺序：

1. 若指定 `--primary`，优先使用该偏移；
2. 否则使用 `--video-length`，或读取 XMP `Container:Item` 的视频长度；
3. 兼容 `GCamera:MicroVideoOffset`、`GCamera:MotionPhotoVideoLength`、`OpCamera:VideoLength`；
4. 长度信息缺失或推导出的边界无效时，扫描尾部 ISO-BMFF `ftyp/moov/mdat` 结构；
5. 将视频起点之前的字节原样写出为静态文件，将起点到文件末尾的字节写出为视频。

拆分不解码、不重写静态容器，因此保留前缀中的 MPF、增益图和 HEIF 辅助图像数据。
它不修复原有元数据，也不会给静态图写入 Live Photo MakerNote。
XMP 解析只覆盖源码中的常见写法，不是完整的 XML/XMP 解析器；畸形数值等情况可能直接报错。

只做拆分时，无需编译 Swift 工具：

```bash
python3 tools/make_livephoto_still.py input.jpg /tmp/source.jpg \
  --video-out /tmp/source.mp4 \
  --id-file /tmp/content-id.txt
```

对于 HEIC 输入，请相应使用 `.heic` 静态输出名；拆分器不会根据扩展名转换格式。
`--id-file` 仅保存生成或指定的配对标识，供后续步骤使用。

自动定位失败但已知有效视频边界时，可以手动指定（以下数值仅为示例）：

```bash
python3 tools/make_livephoto_still.py input.jpg /tmp/source.jpg \
  --video-out /tmp/source.mp4 \
  --primary 8184744
```

`--video-length` 最终仍按视频延伸至文件末尾处理，不支持从中间截取固定长度片段。
手动偏移也不能让任意厂商私有封装变成受支持的 MP4/MOV。

## HDR 实现与画质

[静态图编码工具](<tools/mkstill.swift>) 通过 ImageIO：

1. 根据 headroom 或辅助增益图判断输入是否为 HDR；
2. 在 HDR 路径中解码扩展动态范围，并请求 ISO gain-map 编码；
3. 输出 HEIC/JPEG，同时写入 Apple MakerNote key 17；
4. 回读输出，检查图片能否解码、MakerNote 是否匹配，并报告 headroom；
5. 当源被识别为 HDR 且使用 `preserve` 时，要求输出 headroom 大于 1.01。

这是重新编码，不是原增益图码流或像素的逐字节复制；**SDR 和 HDR 静态图都会重新编码**。
颜色、亮度和细节可能与源图不同，实际 HDR 显示取决于系统、编码器和查看软件。
视频使用 passthrough，但 MOV 容器、元数据及时间字段会改变，并非整个视频文件字节不变。

## Live Photo 配对实现

静态图中写入：

```text
kCGImagePropertyMakerAppleDictionary
key 17 = <ContentIdentifier UUID>
```

MOV 中写入以下文件级 QuickTime 元数据：

```text
com.apple.quicktime.content.identifier = <同一个 UUID>
com.apple.quicktime.still-image-time   = 0
com.apple.quicktime.live-photo.auto    = 1
```

XMP 中的 `apple:ContentIdentifier` 不能代替图片 MakerNote 和 MOV 的配对标识。
当前实现通过 `AVAssetExportSession.metadata` 写入上述键，**没有创建独立的定时元数据轨**，
也没有读取安卓动态照片的静态帧时间戳。不要将其视为对 iPhone 原生 Live Photo 结构的完整复刻；
不同导入路径和系统版本仍需实测。

## 手动流水线

以下示例用于 JPEG Motion Photo；HEIC 输入请同步调整中间静态文件扩展名。

```bash
SRC=/path/to/motion_photo.jpg
CID=$(uuidgen)

python3 tools/make_livephoto_still.py "$SRC" /tmp/source.jpg \
  --video-out /tmp/source.mp4 --uuid "$CID"

bin/mkstill /tmp/source.jpg IMG_LIVE.HEIC "$CID" heic --hdr preserve
bin/mkmov /tmp/source.mp4 IMG_LIVE.MOV "$CID"
bin/validate IMG_LIVE.HEIC IMG_LIVE.MOV
```

**底层拆分、图片编码及视频封装工具会覆盖已有输出，没有一键入口的 `--force` 保护。**
请使用独立的输出路径，不要把原文件作为输出。

视频日期默认尝试从源视频的 `mvhd` 读取，并用于重写输出的 `mvhd/tkhd/mdhd` 创建与修改时间；
源日期不可用时保留导出器生成的日期。该流程不从图片 EXIF 推导日期，也不保证两者原本一致。
需要覆盖视频日期时：

```bash
bin/mkmov source.mp4 IMG_LIVE.MOV "$CID" \
  --date 2026-09-11T02:45:51Z
```

## 验证方式

### 只读结构检查

```bash
bin/validate IMG_LIVE.HEIC IMG_LIVE.MOV
```

[校验工具](<tools/validate.swift>) 会解码静态图、加载视频轨道信息，检查图片标识与 MOV
标识是否一致，以及 MOV 是否存在 `still-image-time` 键。通过时退出码为 0。
它报告 HDR headroom / 增益图，但**不对 HDR 保真作通过判定**；也不逐帧解码视频、不验证
定时元数据轨或静态帧时间、不要求 `live-photo.auto` 存在。结构检查通过不等于 Photos
导入必然成功。

### Photos 实际导入测试（会修改照片库）

```bash
bin/pairtest IMG_LIVE.HEIC IMG_LIVE.MOV
```

[配对测试工具](<tools/pairtest.swift>) 请求照片库权限，将图片和视频以 `.photo` 与
`.pairedVideo` 资源提交给 Photos。应检查输出中的 `ACCEPTED` 和 `live=true`，
并在「照片」中确认播放效果；当前工具的退出码不能可靠区分授权失败或导入被拒绝。
它不是只读检查，测试完成后需手动删除照片库中的测试素材；启用 iCloud 照片时素材还可能同步。
一键转换不会自动运行此测试。

## 工具说明

| 文件 | 作用 |
|---|---|
| [build.sh](<build.sh>) | 编译四个 Swift 工具，缓存保存在 `.build/`，产物放入 `bin/` |
| [motion2live.py](<tools/motion2live.py>) | 一键转换入口 |
| [make_livephoto_still.py](<tools/make_livephoto_still.py>) | JPEG/HEIC 拆分和尾部视频提取 |
| [mkstill.swift](<tools/mkstill.swift>) | MakerNote 写入与 SDR/HDR 静态图编码 |
| [mkmov.swift](<tools/mkmov.swift>) | MOV 重封装、配对元数据和视频时间归一 |
| [validate.swift](<tools/validate.swift>) | 图片解码、配对检查及 HDR 信息报告 |
| [pairtest.swift](<tools/pairtest.swift>) | Photos 实际导入测试 |

## 已知限制与排错

- 普通静态照片（不含尾部视频）不能凭空转换成 Live Photo。
- 特殊厂商封装、畸形 XMP、大型或非常规视频容器可能无法识别；扫描器不是通用媒体修复器。
- 拆分器会把整个输入读入内存，主要面向手机短动态照片，不适合超大媒体文件。
- 若提示缺少编译工具，先执行 `bash build.sh`；源码更新后应重新构建。
  即便使用 `--no-validate`，当前入口仍要求校验二进制存在。
- 编译时报 API 不可用，请检查 macOS 和所选 Xcode/Command Line Tools SDK；
  仅切换 HDR 参数无法解决编译期 API 缺失。
- 如果源视频编码不被 Apple 平台支持，passthrough 可能失败，需要先将视频转成受支持的
  H.264 或 HEVC 等编码；本工具不会自动转码。
- 转换不提供隐私脱敏：图片可能保留拍摄日期、GPS 等源元数据。公开样本或分享输出前请检查。
- 当前没有自动化回归测试套件；发布或批量迁移前，建议先用自己的代表性素材验证。

## 参考

- [Android Motion Photo Format](https://developer.android.com/media/platform/motion-photo-format)
- [Apple ImageIO](https://developer.apple.com/documentation/imageio)：HDR decode/encode 与 ISO gain-map API
- [Apple PhotoKit](https://developer.apple.com/documentation/photokit)
