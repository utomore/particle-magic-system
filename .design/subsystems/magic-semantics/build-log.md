---
id: magic-semantics-build
type: build-log
title: magic-semantics-build
description: 階段四候選的委派展開：立體陣與代價閘門兩項
status: in-progress
created: 2026-08-22
updated: 2026-08-22
parent: magic-semantics
---

# 魔法語意 委派展開紀錄

## 排程

本次只跑**階段四**，且只跑其中兩項。批次澄清（2026-08-22）縮小了範圍，理由記在下方決策表。

| 階段 | 波次 | features | 狀態 |
|---|---|---|---|
| 階段四 | W1 | volumetric-sigil, spell-cost-model | 設計完成，實作未開始 |

**排除在本次之外的項目與理由**：

| feature | 為什麼不在這一輪 |
|---|---|
| sigil-time-axis | 已於 2026-08-22 交付（`F001`，commit `7fa5ce3`），不是本次委派的產物 |
| glyph-semantics | ADR-0014 D7 把「真正的符文語言」指名為**遊戲層的設計＋新的 spec**，那份設計還不存在。沒有它就委派＝讓執行者自己發明一套字母表。契約卡已標記為阻塞中 |
| node-orbit | 契約卡明寫「應與多發動點合流後再做」，合流點是階段五的 caster-follow-anchors。跨階段的相依，階段是硬邊界 |
| time-varying-modulation | 需要 expr-language 的第四種時間掛載點（`expr-fourth-time-mount`，尚未展開）。開發者裁決：等對方先交付 |
| caster-follow-anchors（階段五） | 需要 boundary-host 的 `caster-context-update`（尚未展開）。同上，等 |
| single-precision-params（階段五） | 契約卡明寫「與 particle-simulation 的 `compile-time-narrowing` 同輪」，對方尚未展開。同上，等 |

**跨子系統依賴的處理決定**：一律**等對方先交付**，不採「照介面約定先做」。理由是那三項都要替另一個子系統預先定介面，等於把 Level 2 的決定權下放給 Level 3 的執行者。

## 委派決策記錄

契約類的四項裁決已回寫 `design.md`（volumetric-sigil 與 spell-cost-model 的契約卡各新增「契約補完」小節，glyph-semantics 新增「阻塞中」小節），這裡不重複。以下是不屬 Level 2 的執行取向與排程決定。

| # | 問題 | 開發者決定 | 影響範圍 |
|---|------|-----------|---------|
| D1 | 本次展開範圍 | 只做階段四無外部相依的項目 | 全部 |
| D2 | 未滿足的跨子系統相依要等還是照約定先做 | 一律等對方先交付 | time-varying-modulation、caster-follow-anchors、single-precision-params |
| D3 | glyph-semantics 的定位（ADR-0014 D7 與契約卡牴觸） | 本輪不做；先補遊戲層的符文語言設計 | glyph-semantics |
| D4 | glyph-semantics 若日後要做，既有陣的相容作法 | 照 ADR-0020 §2.4 的先例讀不相交的新位段，預設不取代現有層 | glyph-semantics（未來） |
| D5 | 工作樹與分支 | 開 `feat/magic-semantics-p4`，F001 先 commit（`7fa5ce3`） | 全部 |

**未列入上表但由編排者帶進委派 prompt 的既有專案慣例**（不是本次的新決定，是 repo 已成文的作法）：相容律以差分陳述而非重錄 golden（ADR-0020 D3）；1-to-1 測試對照表逐條落地；新 spec 檔要登記進 `particle-magic.cabal` 的 `other-modules`；工作樹是 CRLF；文檔繁體中文、程式碼與註解英文。

## 配號表

fan out 前預先分配，平行執行不得自行配號。委派模型固定 `sonnet`。

| feature | id | 檔名 | 設計模型 | 實作模型 | 狀態 |
|---|---|---|---|---|---|
| volumetric-sigil | F002 | F002-volumetric-sigil.md | sonnet | sonnet | design-done |
| spell-cost-model | F003 | F003-spell-cost-model.md | sonnet | sonnet | design-done |

實作順序（階段內序列）：F002 → F003。兩者的檔案交集小（F002 動 M2／M5／`emitterBounds`，F003 動 M4 的預算段與 C ABI），但同一子系統仍照序列跑。

## 待確認假設彙總

各 feature 文檔「待確認假設」段落的彙總。閘門裁決欄在階段閘門由開發者填。

| 來源 | 假設 | 採取的判斷 | 閘門裁決 |
|---|---|---|---|
| F002 A1 | `SigilVolume` 要不要現在就留可調欄位（層距、層數上限） | 這一輪做成零欄位純開關；日後要加欄位不必動 `Circle` 的形狀或 JSON 鍵 | 待裁決 |
| F002 A2 | 四個節點裝飾點與中心點要不要一起堆疊 | 不堆疊——它們是 func-0006 §4.4 的裝飾點而非陣的筆畫；要改需重新裁決它們固定的 12／16 粒配額怎麼跨層分攤 | 待裁決 |
| F002 A3 | 層數公式 `min 5 (max 2 (1 + occCount))` 與 `layerGap = 0.12` | 屬 Level 3 實作細節，手動 smoke 覺得太密／太疏可在實作階段直接調，不需重新委派 | 待裁決 |
| F002 A4 | 堆疊時粒子總量該不該跟著層數放大 | 選「總量不變、密度攤薄」，不新增 `sigilBudget`／`budgetCap`、不新增 `CompileError`。要等比放大得重新裁決預算條款 | 待裁決 |
| F003 A1 | 法力權重表的具體常數 | 依既有 fold 的顆粒度給出有區分度的小整數表；日後調平衡只改 `manaCost` 內部常數與 `ManaWeightSpec` 的期望值，不動任何簽名 | 待裁決 |
| F003 A2 | `refusalCode`／`pm_cast_ex` 的錯誤碼分類本輪不分辨兩類 | 本輪不開 boundary/FFI 入口，現有入口永遠產生不出 `ManaExceeded`，改了沒有可測的觀察點。未來接上 FFI 時要一併補 | 待裁決 |

## 委派品質觀察

編排者在收件時發現、已機械性修正、不影響設計內容的問題：

| 波次 | 觀察 | 處理 |
|---|---|---|
| W1 設計 | F002、F003 兩份文檔都混入簡體字（`对`／`应`／`总`／`层`／`维` 等），違反專案的繁體中文慣例 | 編排者以字元對照表機械轉換並重新正規化為 CRLF；未改動任何設計內容 |
| W1 設計 | 兩份文檔產出時的行尾不一致 | 統一正規化為 CRLF |

編排者另行查證的宣稱：F003 宣稱 `PM_ERR_MANA = -8` 是下一個未用的錯誤碼——打開 `include/particle_magic.h` 與 `bindings/csharp/ParticleMagic.cs` 確認 −1..−7 已用、−8 未用，宣稱成立。

## 階段結果

### 階段四

**W1 設計（完成，commit 待補）**

| feature | id | 狀態 | 產出 |
|---|---|---|---|
| volumetric-sigil | F002 | design-done | 7 個 Todo、7 份 1-to-1 測試、`depends-on: [F001]`（執行者查證介面表後自行修正，F001 已 done 不阻塞） |
| spell-cost-model | F003 | design-done | 5 個 Todo、5 份 1-to-1 測試、`depends-on: []` |

兩份都回報無阻塞項、皆未動任何 `src/`／`test/`／`tools/` 檔案、皆回報不需要新 ADR、也不需要修改 Level 2 契約本身。

**帶到閘門的上層變更建議**（來自 F003）：`design.md` 資料流管線「驗證」段目前寫「執行期只檢查一件事：粒子總量是否超過護欄」，F003 **實作完成後**這句話需要改成「粒子總量，以及（給了上限時）法力代價」。設計階段不動，實作完成後由編排者在閘門一併處理。

**W1 實作**：尚未開始。順序 F002 → F003。
