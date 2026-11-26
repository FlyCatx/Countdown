# 设计源

`countdown_launcher_A.svg` 是启动图标的唯一母版（A 版）：白底、#1C52D4
表盘圆弧与表针及轴心、两枚 #A8CDFF 刻度。预览图中灰色衬底不属于图标。

Android 启动图标资源根据母版生成，位于本仓库的 `android/app/src/main/res/`。

| 资源 | 用途 |
|---|---|
| `mipmap-{mdpi..xxxhdpi}/ic_launcher.png` | API 24–25 传统方形图标（白底圆角） |
| `mipmap-{mdpi..xxxhdpi}/ic_launcher_round.png` | 传统圆形图标 |
| `mipmap-anydpi-v26/ic_launcher.xml`、`ic_launcher_round.xml` | API 26+ 自适应图标声明 |
| `drawable/ic_launcher_foreground.xml` | 自适应前景矢量图（108dp 画布，母版 128 视口） |
| `drawable/ic_launcher_background.xml`、`values/colors.xml` | 自适应背景纯白 |

修改图标时，先更新 SVG 母版，再重新导出上表所列的 Android 启动资源。
