# LICENSE / LIC_FILES_CHKSUM 撰寫原則

這是整份 recipe 裡**唯一有法遵風險**的欄位，寫錯的代價比 build 失敗嚴重得多
（可能導致產品出貨後的授權合規問題）。`scripts/license_scan.py` 只是輔助，
最終判斷永遠要有人（agent 或使用者）實際讀過授權文字。

## 流程

1. 跑 `scripts/license_scan.py <stage_dir>`，拿到候選授權檔清單與各自的 md5、
   關鍵字猜測的 SPDX 值。
2. **打開檔案內容實際看過**，確認關鍵字猜測是否正確 —— 尤其要注意：
   - 授權**版本**（GPL-2.0 vs GPL-2.0-only vs GPL-2.0-or-later 意義不同：
     `-only` 代表只能用該版本，`-or-later` 代表可用該版本或之後任何版本，
     upstream 授權檔的用字通常會講清楚是哪一種，不要憑感覺猜）。
   - 是否為**雙授權**或**多檔案不同授權**（常見於某些 library 對 code 用一種授權、
     對文件/範例用另一種）。
   - 原始碼檔案內是否有**個別檔頭聲明**跟頂層 LICENSE 檔不一致的情況（vendored
     third-party 檔案常見）。
3. `recipetool create` 也會自己猜 license，跟 `license_scan.py` 的結果互相對照，
   兩者不一致時要更謹慎，不要隨便挑一個。
4. 若掃描不到獨立授權檔，檢查主要原始碼檔案的檔頭註解（前 20-30 行常見有
   `SPDX-License-Identifier: ...` 或完整授權聲明文字）。

## LICENSE 欄位格式

- 使用 SPDX identifier，且用現代寫法（`GPL-2.0-only` 而非舊式 `GPL-2.0`）。
- 多授權：
  - `LICENSE = "MIT & BSD-3-Clause"` —— AND，代表整體受兩種授權共同約束
    （例如 code 是 MIT，內嵌的某個第三方檔案是 BSD-3-Clause，兩者都要遵守）。
  - `LICENSE = "GPL-2.0-only | Commercial"` —— OR，使用者可擇一遵守
    （常見於同時提供開源與商業授權的雙授權專案）。
- 完全沒有可辨識授權、或是內部專有程式碼：`LICENSE = "CLOSED"`，並在 recipe
  加 comment 說明依據。

## LIC_FILES_CHKSUM 格式

```
LIC_FILES_CHKSUM = "file://COPYING;md5=<hash>"
```

- 多檔案用空白分隔多個 `file://...;md5=...` 項目。
- 只取檔案某個區間（授權聲明寫在原始碼檔頭時）：
  `file://src/main.c;beginline=1;endline=20;md5=<hash>`
- md5 值必須是**該檔案（或該行區間）內容的實際 md5sum**，不能用猜的。
  `license_scan.py` 算的是整檔 md5；若只取行區間，要自己用
  `sed -n '1,20p' file | md5sum` 之類的方式重算對應區間的 md5。

## 給使用者的提醒（一定要放進最終總結）

不管信心多高，在成功收尾的總結裡，**LICENSE 判斷依據永遠要明確列出來讓使用者複查**
——包含你參考了哪個檔案、看到了什麼關鍵字、以及最終選定的 SPDX 值。這不是這個 skill
可以完全自動化並免責的部分。
