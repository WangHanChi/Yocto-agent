# BitBake Recipe 變數速查

給 agent 在寫/改 recipe 時對照，不是完整的 BitBake 手冊替代品。權威來源永遠是
`bitbake-user-manual` 與 `dev-manual` (docs.yoctoproject.org)。

## 必備 metadata

```
SUMMARY = "一行簡短描述，不要句點結尾"
DESCRIPTION = "較長描述，可以省略但建議寫"
HOMEPAGE = "https://upstream-project-homepage"
LICENSE = "MIT"                                  # SPDX 格式，見 license-guide.md
LIC_FILES_CHKSUM = "file://COPYING;md5=<32位hex>"
```

- `LICENSE` 多授權用 `&`（AND，整個套件都受兩種授權約束）或 `|`（OR，使用者可擇一），例如
  `LICENSE = "MIT & BSD-3-Clause"`。
- `LIC_FILES_CHKSUM` 可以指定多個檔案，用空白分隔；也可以只取檔案的某個行區間：
  `file://src/main.c;beginline=1;endline=20;md5=...`（授權聲明寫在原始碼檔頭時常用）。

## 版本與來源

```
PV = "1.2.3"          # 版本，git 來源常見 "1.2.3+git${SRCPV}" 或直接用 tag
PR = "r0"              # recipe revision，改 recipe 邏輯但沒改上游版本時遞增
SRC_URI = "git://github.com/org/repo.git;protocol=https;branch=main"
SRCREV = "abcdef0123456789..."   # 明確 commit hash，生產用途一定要 pin
S = "${WORKDIR}/git"    # 原始碼解壓/checkout 後的根目錄，git fetcher 預設就是這個
```

tarball 來源：

```
SRC_URI = "https://example.com/foo-${PV}.tar.gz"
SRC_URI[sha256sum] = "<64位hex>"
S = "${WORKDIR}/foo-${PV}"   # 依實際解壓後的目錄名調整
```

patch 檔案（放在 recipe 同目錄下的 `files/`）：

```
SRC_URI += "file://0001-fix-cross-compile.patch"
```

## 相依關係

```
DEPENDS = "zlib openssl"          # build-time 相依（host/target 依 class 決定）
RDEPENDS:${PN} = "bash"           # runtime 相依，注意 PACKAGE override 語法用 ':'（新版 bitbake）
DEPENDS += "foo-native"           # 顯式要求 native（host 端）版本的 foo
```

## Build 行為

```
inherit cmake            # 或 autotools / meson / cargo / setuptools3 / module ...

EXTRA_OECMAKE = "-DBUILD_TESTS=OFF"
EXTRA_OECONF = "--disable-doc"     # autotools
EXTRA_OEMAKE = "CC='${CC}'"        # 手動 make 類

do_install:append() {
    install -d ${D}${bindir}
    install -m 0755 ${B}/foo ${D}${bindir}/foo
}
```

- 覆寫任務用 `do_xxx() { ... }`，附加/前置行為用 `do_xxx:append()` / `do_xxx:prepend()`，
  不要動不動整個覆寫掉 class 提供的預設實作，能 append 就不要 override。

## Packaging

```
FILES:${PN} += "${libdir}/foo/*.so"
FILES:${PN}-dev += "${includedir}/foo"
PACKAGES =+ "${PN}-tools"
```

## PACKAGECONFIG（讓上游 optional feature 可被 distro/local.conf 開關）

```
PACKAGECONFIG ??= "ssl"
PACKAGECONFIG[ssl] = "--with-ssl,--without-ssl,openssl"
```
格式：`<flag>[<config>] = "<開啟時的 configure 參數>,<關閉時的參數>,<額外 DEPENDS>,<額外 RDEPENDS>"`。
