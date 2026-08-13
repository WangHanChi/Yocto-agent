# SRC_URI Fetcher 語法

## git

```
SRC_URI = "git://github.com/org/repo.git;protocol=https;branch=main"
SRCREV = "<明確 commit hash>"
S = "${WORKDIR}/git"
```

- `protocol=https`（或 `ssh`）幾乎一定要寫，否則 bitbake 的 git fetcher 預設會嘗試
  `git://` 原生協定，多數現代 hosting 服務不支援。
- `branch=` 要跟 `SRCREV` 對得上（`SRCREV` 必須是那個 branch 歷史上的一個 commit）。
- 有 submodule 用 `gitsm://` 取代 `git://`，其餘語法相同。
- `SRCREV = "${AUTOREV}"` 會每次都抓 branch 最新 commit —— **只適合開發迭代**，正式/可
  重現的 recipe 一律 pin 明確 hash。

## wget / https tarball

```
SRC_URI = "https://example.com/foo-${PV}.tar.gz"
SRC_URI[sha256sum] = "<64位hex，用 sha256sum 算>"
S = "${WORKDIR}/foo-${PV}"
```

- `S` 要跟實際解壓後的頂層目錄名一致，跟 tarball 檔名不一定相同，解壓後看一下。

## file:// 本機檔案（含 patch）

```
SRC_URI = "file://foo-1.0.tar.gz \
           file://0001-fix-cross-compile.patch"
```

- 只有放在 recipe 同目錄的 `files/` 子目錄（或跟 recipe 同名的資料夾）下的檔案能用
  `file://` 引用。本機打包的 vendor tarball（見下方）就是走這條路。
- Patch 檔案照套用順序列在 SRC_URI，bitbake 會依序 apply。

## 本機路徑輸入的兩種模式

### (1) externalsrc —— 開發模式，快速迭代，不可重現

```
inherit externalsrc
EXTERNALSRC = "/home/user/dev/foo"
EXTERNALSRC_BUILD = "/home/user/dev/foo/build"   # out-of-tree build 時指定，可省略
```

- 完全跳過 fetch/unpack，直接對這個路徑做 in-place build，改完原始碼馬上能 `bitbake -c compile foo`
  看到效果，非常適合邊改邊測。
- **代價**：這份 recipe 沒有版本鎖定、換一台機器/換時間點結果不保證一樣，正式化前一定要
  換成下面的 vendor tarball 或 git+SRCREV 模式。

### (2) vendor tarball —— 可重現模式

把本機目錄打包後放進 layer：

```sh
tar -czf files/foo-1.0.tar.gz -C /path/to/local/dir .
```

```
SRC_URI = "file://foo-1.0.tar.gz"
S = "${WORKDIR}/foo-1.0"
```

適合「這份 code 沒有上游 repo，但要一份能被別人/CI 重現 build 的 recipe」的情境。

## npm / crate（特殊 fetcher，需搭配對應 class）

- `npm://` 搭配 `meta-nodejs` 提供的 node class。
- `crate://` 搭配 `cargo`/`cargo-bitbake` 產生的 crate 清單（見 `bbclasses.md` 的 cargo 章節）。
- 兩者都需要額外 layer/工具支援，不是 oe-core 內建就能直接用。
