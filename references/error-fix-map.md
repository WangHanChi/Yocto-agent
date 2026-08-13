# Build 失敗症狀 → 成因 → 修法

`scripts/parse_bitbake_log.py` 的分類（category）對應到下面的表格。每輪 build-fix loop
失敗時，先看 category，再照這裡的方向動手，不要每次都從零開始重新分析 log。

| category | 常見成因 | 修法 |
|---|---|---|
| `fetch-checksum-mismatch` | `SRC_URI[sha256sum]` 寫錯；或 tarball URL 指到一個會變動內容的位置（例如 GitHub 的 auto-generated tarball 在同一 tag 下有時內容會變）；或用 `SRCREV` 抓 git 但寫的 hash 不對 | 重新用 `sha256sum <下載下來的檔案>` 算出正確值更新；git 來源改抓 `git rev-parse HEAD` 的實際值。 |
| `fetch-failure` | SRC_URI 語法錯（少了 `protocol=https`、branch 名打錯）；URL 本身失效；或環境設了 `BB_NO_NETWORK=1` 但 `DL_DIR` 裡沒有預先快取好的來源 | 檢查 SRC_URI 語法對照 `references/src-uri-fetchers.md`；離線環境要確認 `DL_DIR` 已有對應檔案。 |
| `configure-missing-tool` | `do_configure` 呼叫的 host 端工具（如 `pkg-config`、`autoconf`、某個 `*-native` 套件）不存在 | 把該工具對應的 recipe 加進 `DEPENDS`，通常是 `<pkg>-native`；用 `bitbake-layers show-recipes <pkg>` 確認正確 recipe 名稱。 |
| `compile-missing-header` | 缺少提供該 header 的 `-dev` 套件 | 找出 header 屬於哪個上游函式庫，把對應 recipe 加進 `DEPENDS`（例如 `zlib.h` → `DEPENDS += "zlib"`）。 |
| `link-missing-lib` | 同上，但發生在連結階段；或 `PACKAGECONFIG` 沒開啟需要的功能 | 加 `DEPENDS`；檢查是否需要調整 `PACKAGECONFIG`。 |
| `install-no-files` | 上游 build system 的 install target 跟預期路徑不同，`do_install` 沒把東西放進 `${D}`；或 `FILES:${PN}` 沒涵蓋實際安裝路徑 | 先手動在 stage 目錄跑一次上游的 install 指令確認實際輸出路徑，再對應調整 `do_install` 或 `FILES:${PN}`。 |
| `qa-issue` | insane.bbclass 檢查到 packaging 問題：rpath 指向 build 目錄、binary 被上游自己 strip 過、buildpaths 洩漏、`.la` 檔案殘留等 | 優先修根因（例如加 `EXTRA_OECONF = "--disable-static"` 消除 `.la`／關掉上游自己的 strip）。只有能清楚說明安全性時才用 `INSANE_SKIP:${PN} += "already-stripped"` 之類的例外，並在 recipe 留 comment 講清楚為什麼。 |
| `license-checksum-mismatch` | 授權檔內容跟 recipe 裡的 md5 對不上 | `md5sum <授權檔>` 重算更新；同時確認 `LICENSE` 欄位有沒有需要跟著改（授權檔內容變了可能代表授權也換了）。 |
| `recipe-name-collision` | 新 recipe 的 `PN` 跟其他 layer 裡已有的 recipe 撞名 | 換一個更明確的 `PN`，或用 `BBFILE_PRIORITY` 調整自己 layer 的優先權（後者只在你確定要覆蓋別的 layer 時用）。 |
| `parse-error` | recipe 語法錯、變數名打錯、`inherit` 了不存在的 class | 用 `bitbake -e <pn>` 直接看完整展開後的錯誤訊息，通常會指出確切行號。 |
| `ptest-failure` | 套件本身的測試邏輯失敗，可能跟 cross-compile 環境有關（測試假設 host==target） | 先確認是不是已知的 upstream cross-compile 測試限制，必要時在 recipe 排除特定測試，而不是整個關掉 ptest。 |
| `task-failed`（無其他更細分類時的 fallback） | 泛用訊息，實際原因要看該 task 前面幾行的詳細輸出 | 針對訊息裡指出的 `do_xxx` task，往上讀更多 context；必要時直接看 `${WORKDIR}/temp/log.do_xxx` 全文。 |

## 一般原則

1. **一次只改一件事**，改完立刻重跑，才知道是不是這個改動真的解決問題。
2. 同一個錯誤出現第二次、但你已經改過對應項目 → 表示你的假設可能錯了，換個角度看 log，
   不要重覆套用同一個修法。
3. QA 類錯誤（`qa-issue`）幾乎都代表真的有 packaging 問題，不要為了讓 build 過而濫用
   `INSANE_SKIP`。
