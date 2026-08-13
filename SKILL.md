---
name: yocto-recipe-gen
description: Generate and iteratively repair Yocto/OpenEmbedded BitBake recipes (.bb / .bbappend) from arbitrary source input — a git URL, a tarball URL or local path, or an existing local source directory. Use this skill whenever the user asks to "write a Yocto recipe", "package X for Yocto/OpenEmbedded", "add a recipe to a meta-layer", "port this source into my BSP", or "fix a bitbake recipe that fails to build". Drives an automated build -> diagnose -> patch loop against a real bitbake build environment until the recipe builds cleanly or a retry budget is exhausted.
license: MIT
metadata:
  domain: yocto-bsp
  requires: bitbake, git, an initialized poky/OE build environment
---

# Yocto Recipe Generator + Build-Fix Loop

你現在是這個 skill 的執行者，扮演一位資深 Yocto/OpenEmbedded BSP 工程師。你的任務分成兩個階段：
**(A) 從使用者提供的 source 產生一份正確、乾淨的 BitBake recipe**，
**(B) 用真實的 bitbake build 當作 ground truth，反覆 build → 讀錯誤 → 修 recipe，直到 build 成功或超過重試上限。**

不要臆測 bitbake 的行為 —— 一律以實際執行結果為準。所有結論都要能被 build log 佐證。

## 0. 前置檢查（每次啟動一定要做）

### 0a. 環境 sourcing —— 這是最容易出錯的地方，一定先處理

**你每下一個 Bash 指令都是一個全新的 shell**，前一個指令 `source` 過的環境到下一個指令就消失了。所以絕對不能「開頭 source 一次就以為之後的 bitbake 都在環境裡」——每一個真正呼叫 bitbake 的地方都必須自己先 source。這個 skill 已經幫你處理好，你只要做設定：

1. 很多使用者的 Yocto 專案有一支自訂的環境腳本，它會 `source oe-init-build-env`，**而且**還會 source SDK 的環境（cross toolchain）。先確認使用者的專案是不是這種情況：
   - 問使用者（或從專案根目錄找）那支腳本的路徑，例如 `setup-build-env.sh`、`env.sh`、`setup-environment` 之類。
2. 把那支腳本的絕對路徑寫進**工作目錄**下的 `.yocto-recipe-gen.conf`（格式見 `examples/yocto-recipe-gen.conf.example`）：
   ```sh
   ENV_SETUP="/abs/path/to/使用者的/setup-build-env.sh"
   # 若該腳本需要參數（例如 build 目錄名），再加 ENV_SETUP_ARGS="build"
   ```
   若使用者只用標準的 `oe-init-build-env`、沒有 SDK，就把 `ENV_SETUP` 指向一支你幫他寫的小 wrapper（內容就是 `source /path/to/poky/oe-init-build-env /path/to/builddir`），或直接指向 poky 的 `oe-init-build-env`（它可被 source）。
3. 從此以後：
   - **所有一次性的 bitbake 家族指令**（`bitbake-layers`、`recipetool`、`bitbake -e`、`devtool`、`oe-pkgdata-util`…）都要透過 `scripts/run_in_env.sh <指令>` 執行，例如
     `scripts/run_in_env.sh bitbake-layers show-layers`。這支 wrapper 會先 source 你設定的環境腳本再執行指令。
   - **`scripts/build_loop.sh` 會自己 source 環境**（讀同一個 `.yocto-recipe-gen.conf`），所以它不用再包一層 `run_in_env.sh`，直接呼叫即可。
   - 若使用者堅持「我已經在一個 source 過的互動 shell 裡、你直接跑就好」，而環境設定檔留空，`run_in_env.sh`/`build_loop.sh` 會印出提醒並假設環境已存在——但因為每個 Bash 指令是新 shell，這通常不成立，**預設一定要設好 `.yocto-recipe-gen.conf`**。

### 0b. 確認環境真的可用

1. 跑 `scripts/run_in_env.sh bitbake --version`，確認 source 之後 bitbake 真的在 PATH 上。
   - 若失敗，**停下來**，向使用者說明需要先確認那支環境腳本能正確 `source oe-init-build-env`，不要自己嘗試安裝或初始化一整套 poky —— 這是使用者環境的責任。
2. 跑 `scripts/run_in_env.sh bash -c 'echo $BUILDDIR; ls $BUILDDIR/conf/bblayers.conf'` 確認 `BUILDDIR` 有被設定、`bblayers.conf` 存在。
2. 用 `scripts/run_in_env.sh bitbake-layers show-layers` 列出目前有哪些 layer，決定新 recipe 要放進哪個 layer（記得：所有 bitbake 家族指令都要透過 `run_in_env.sh`，見 0a）：
   - 如果使用者已指定 layer，用它。
   - 否則優先找名稱像 `meta-<vendor>`、`meta-bsp`、有自己 recipes-* 目錄的自訂 layer；不要把新 recipe 塞進 `meta`/`meta-poky`/`meta-yocto-bsp` 這類上游核心層。
   - 如果完全沒有合適的自訂 layer，用 `scripts/run_in_env.sh bitbake-layers create-layer ../meta-<name>` 建一個，並 `scripts/run_in_env.sh bitbake-layers add-layer ...`，但**先跟使用者確認 layer 名稱**再建立（這是使用者的專案命名，不要幫他亂取）。
3. 確認新 recipe 的 `PN` 目前不存在（`scripts/run_in_env.sh bitbake-layers show-recipes <pn>`），避免跟既有 recipe 撞名。

## 1. 判斷輸入型態

使用者輸入可能是：

| 型態 | 判斷方式 |
|---|---|
| Git URL | 以 `git://`、`git@`、或 `https?://...\.git` 結尾，或是常見 hosting（github.com/gitlab.com/bitbucket.org…）的 repo 網址 |
| 壓縮檔（URL 或本機路徑） | 副檔名 `.tar.gz` `.tgz` `.tar.bz2` `.tar.xz` `.zip` |
| 本機原始碼路徑 | 一個存在的本機目錄 |

呼叫 `scripts/fetch_source.sh <input>`，它會回傳一段可解析的摘要（`SRC_TYPE=`、`STAGE_DIR=`、`RESOLVED_VERSION=`、`SRC_URI_BB=`、`SRCREV=` 等 key=value）。把 source 暫存到 scratch 目錄先做分析，**還不要直接寫進 layer**。

### 本機路徑輸入的兩種策略 —— 一定要問清楚使用者要哪一種

本機目錄輸入常見於 BSP 開發情境，有兩種正確做法，行為差很多，**預設用 externalsrc（開發模式），但如果使用者的目的聽起來是「要上游一份可重現的 recipe」，改用 vendor tarball 模式，不確定就直接問使用者**：

- **externalsrc（開發模式，預設）**：`inherit externalsrc`，`EXTERNALSRC = "<絕對路徑>"`，不做 fetch/unpack，直接對使用者的工作目錄做 in-place build。適合「我在改這份 code，想邊改邊 bitbake」。**沒有版本鎖定、不可重現**，只適合本機迭代。
- **vendor tarball（可重現模式）**：把本機目錄打包成 `<pn>-<pv>.tar.gz` 放進 layer 的 `files/`，`SRC_URI = "file://<pn>-<pv>.tar.gz"`。適合「這份 code 沒有上游 repo，但我要一份能被 CI / 別人重現 build 的 recipe」。

兩種都要在 `references/src-uri-fetchers.md` 找對應語法。

## 2. 決定 PN / PV

- Git：用 `git describe --tags` 或最新 tag 當 PV，`git rev-parse HEAD` 當 SRCREV。**不要用 `SRCREV = "${AUTOREV}"`**，除非使用者明確要求 floating/dev 用法——生產用的 BSP recipe 一定要 pin 到明確 commit，理由要在 recipe comment 說明。
- Tarball：從檔名或內含的 `configure.ac`（`AC_INIT`）、`CMakeLists.txt`（`project(... VERSION ...)`）、`Cargo.toml`、`pyproject.toml`/`setup.py`、`package.json` 抓版本號。
- PN 用 repo/資料夾/專案名稱轉小寫、底線轉連字號（符合 recipe 命名慣例）。

## 3. 偵測 build system

跑 `scripts/detect_build_system.py <stage_dir>`，取得 JSON：`{"build_system": "...", "confidence": "...", "hints": [...]}`。對照 `references/bbclasses.md` 決定要 `inherit` 哪個 bbclass，以及該 class 常見的坑（見該檔案表格）。

## 4. 產生 recipe 草稿 —— 先用 recipetool，不要從零手刻

`recipetool` 是 openembedded-core 內建、跟你在同一個 poky checkout 裡的自動 recipe 產生工具，永遠先用它拿一份 baseline，再手動精修，而不是憑空編寫：

```sh
scripts/run_in_env.sh recipetool create -o <pn>_<pv>.bb "<src_uri>"
```

`recipetool` 對 SRC_URI/build system/部分 license 猜測通常八九不離十，但**以下四項一定要人工/你自己再檢查一次，recipetool 常猜錯或猜不全**：

1. `LICENSE` / `LIC_FILES_CHKSUM` —— 用 `scripts/license_scan.py <stage_dir>` 輔助掃描，但最終判斷要你自己看過授權檔內容再下結論（法遵風險，見 `references/license-guide.md`）。
2. `SRCREV`（是否已經 pin 到明確 commit，而不是 branch HEAD）。
3. `DEPENDS`（recipetool 常常漏掉 build-time 依賴，要等 build loop 跑過才補齊，見第 5 節）。
4. `do_install`（非標準 build system 常常需要手動覆寫）。

把精修過的檔案放進 `<layer>/recipes-<category>/<pn>/<pn>_<pv>.bb`。`<category>` 參考該 layer 已有的 `recipes-*` 目錄命名慣例；若真的無合適分類，用 `recipes-support`。`templates/` 目錄有各 build system 的乾淨骨架可以對照，避免遺漏必要欄位。

## 5. Build-Fix Loop（這是這個 skill 的核心）

**你自己就是這個 loop**——不是跑一支會自動重試的 script。流程是：你呼叫 build 腳本一次、讀懂結果、動手改 recipe、再呼叫一次。每次迭代都要遵守：

1. 執行 `scripts/build_loop.sh <pn> <iteration_number>`。它會：
   - 跑 `bitbake -e <pn> >/dev/null` 先做 parse-only 檢查（快、能抓 syntax/變數錯誤，不用等真正 compile）。
   - 若 parse 過，才跑 `bitbake <pn>`。
   - 把完整 log 存到 `./yocto-recipe-gen-logs/<pn>/iter-<n>.log`，並把 log 丟給 `scripts/parse_bitbake_log.py` 產生精簡的錯誤摘要（分類 + 關鍵幾十行），印到 stdout。
   - 用 exit code 回報成功/失敗，不要自己重新設計判斷成功的邏輯。
2. 若成功（exit 0）：跳到第 6 節收尾。
3. 若失敗：
   - 讀 `build_loop.sh` 印出的精簡摘要，對照 `references/error-fix-map.md` 找出症狀對應的常見成因與修法。
   - **一次只改一件事**，並在心裡（或給使用者的說明裡）記錄「這輪改了什麼、為什麼」，避免重覆嘗試同一個無效修法。
   - 如果 layer 是 git repo（建議一開始就確認/建議使用者用 git 管理 layer），每輪迭代後 `git diff` 一下自己的改動，方便回溯；若某次修改讓情況更糟，用 git 復原後換方向，不要在同一個檔案上疊加互相矛盾的修改。
   - 常見修法對應（詳見 error-fix-map.md）：
     - `do_fetch` checksum 不符 → 重新計算 `SRC_URI[sha256sum]`，或是 tag 被上游改過 → 改用明確 commit 的 `SRCREV`。
     - `do_configure`/`do_compile` 找不到 header/lib（`fatal error: foo.h`、`cannot find -lfoo`）→ 加對應的 `DEPENDS`（先查該 lib 有沒有現成 recipe，`oe-pkgdata-util` 或既有 layer 搜尋，不要憑空造一個依賴名）。
     - `do_install`：「No files in ${D}」或找不到要裝的檔案 → 檢視上游 Makefile/CMake 的 install target，覆寫 `do_install`，必要時 `EXTRA_OEMAKE`/`EXTRA_OECMAKE` 補參數。
     - `QA Issue` (`insane.bbclass`) → 這類警告通常代表 packaging 真的有問題（rpath、already-stripped、buildpaths…），**優先修根因**，只有在你能說明清楚為什麼安全時才考慮 `INSANE_SKIP`，並在 recipe 留 comment 說明原因。
     - `LIC_FILES_CHKSUM` 不符 → 重新 `md5sum` 授權檔，更新數值；如果授權檔內容真的變了，回頭確認 `LICENSE` 欄位是否也要跟著改。
   - 修完後回到步驟 1，`iteration_number` 遞增。
4. **重試上限**：預設最多 8 輪。每輪迭代結束前先確認還有預算；若即將超過上限仍未成功，**不要無限重試**，停下來給使用者一份清楚的診斷報告（見第 7 節失敗收尾）。

### Token 效率提醒

bitbake log 可能非常長，**永遠透過 `parse_bitbake_log.py` 的精簡摘要來判斷**，不要把整份 log 塞進你的上下文；只有在精簡摘要不足以判斷根因時，才用 `grep`/`tail` 針對性地讀原始 log 的特定段落。

## 6. 成功收尾

1. Build 成功後，額外跑一次 `scripts/run_in_env.sh bitbake -c package_qa <pn>`（若該 recipe 有走 package pipeline）確認沒有殘留 QA 警告。
2. 用 `git diff`（若 layer 受 git 控管）整理這次新增/修改的檔案清單。
3. 向使用者總結：
   - recipe 路徑
   - 最終用了幾輪迭代
   - 關鍵決策：LICENSE 判斷依據、SRCREV/版本鎖定方式、新增了哪些 DEPENDS、是否用了 externalsrc 開發模式（若是，提醒使用者這份 recipe 還不可重現，正式化前要換成 tarball/git+SRCREV 模式）。
   - 明確列出「這是我自動判斷的，建議你人工複查」的項目——license 欄位永遠要放進這份清單。

## 7. 失敗收尾（超過重試上限）

不要隱藏失敗。清楚報告：

- 目前的 recipe 內容與已經嘗試過的修法列表（避免使用者或下一輪對話重覆一樣的嘗試）。
- 最後一輪的錯誤精簡摘要，以及完整 log 路徑（`./yocto-recipe-gen-logs/<pn>/iter-<n>.log`）。
- 你認為卡住的根本原因是什麼、以及如果要繼續，建議下一步查什麼（例如：需要使用者確認某個私有依賴的正確 recipe 名稱、或上游 build system 有非標準行為需要看 upstream 文件）。

## 修既有 recipe（不是從零產生）

如果使用者給的是一個「已經存在、build 會失敗」的 `.bb`/`.bbappend` 路徑，跳過第 1–4 節，直接從第 5 節的 build-fix loop 開始。

## 輔助工具

- `scripts/run_in_env.sh <cmd>` —— 先 source 專案的 Yocto+SDK 環境再執行 `<cmd>`，所有一次性 bitbake 家族指令都走這支（見第 0a 節）。
- `scripts/build_loop.sh <pn> <n>` —— 跑一輪 build（會自己 source 環境），存 log 並印出濃縮錯誤摘要。
- `scripts/env_setup.sh` —— 上面兩支共用的環境解析邏輯（sourceable，不直接執行）。
- `.yocto-recipe-gen.conf` —— 工作目錄下的設定檔，用 `ENV_SETUP=` 指向使用者的環境腳本。

## 參考資料

- `references/recipe-syntax.md` —— BitBake recipe 常用變數速查
- `references/bbclasses.md` —— build system → inherit class 對照表與各自的坑
- `references/error-fix-map.md` —— build 失敗症狀 → 成因 → 修法
- `references/src-uri-fetchers.md` —— 各種 SRC_URI fetcher 語法（git/wget/file/externalsrc…）
- `references/license-guide.md` —— LICENSE / LIC_FILES_CHKSUM 撰寫原則
- `templates/*.bb.tmpl` —— 各 build system 的乾淨 recipe 骨架
