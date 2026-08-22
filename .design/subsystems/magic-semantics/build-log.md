---
id: magic-semantics-build
type: build-log
title: magic-semantics-build
description: 階段四候選的委派展開：立體陣與代價閘門兩項
status: done
created: 2026-08-22
updated: 2026-08-22
parent: magic-semantics
---

# 魔法語意 委派展開紀錄

## 排程

本次只跑**階段四**，且只跑其中兩項。批次澄清（2026-08-22）縮小了範圍，理由記在下方決策表。

| 階段 | 波次 | features | 狀態 |
|---|---|---|---|
| 階段四 | W1 | volumetric-sigil, spell-cost-model | done（閘門通過） |

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
| volumetric-sigil | F002 | F002-volumetric-sigil.md | sonnet | sonnet | impl-done |
| spell-cost-model | F003 | F003-spell-cost-model.md | sonnet | sonnet | impl-done |

實作順序（階段內序列）：F002 → F003。兩者的檔案交集小（F002 動 M2／M5／`emitterBounds`，F003 動 M4 的預算段與 C ABI），但同一子系統仍照序列跑。

## 待確認假設彙總

各 feature 文檔「待確認假設」段落的彙總。閘門裁決欄在階段閘門由開發者填。

| 來源 | 假設 | 採取的判斷 | 閘門裁決 |
|---|---|---|---|
| F002 A1 | `SigilVolume` 要不要現在就留可調欄位（層距、層數上限） | 這一輪做成零欄位純開關；日後要加欄位不必動 `Circle` 的形狀或 JSON 鍵 | 接受 |
| F002 A2 | 四個節點裝飾點與中心點要不要一起堆疊 | 不堆疊——它們是 func-0006 §4.4 的裝飾點而非陣的筆畫；要改需重新裁決它們固定的 12／16 粒配額怎麼跨層分攤 | 要改 → E001 |
| F002 A3 | 層數公式 `min 5 (max 2 (1 + occCount))` 與 `layerGap = 0.12` | 屬 Level 3 實作細節，手動 smoke 覺得太密／太疏可在實作階段直接調，不需重新委派 | 接受 |
| F002 A4 | 堆疊時粒子總量該不該跟著層數放大 | 選「總量不變、密度攤薄」，不新增 `sigilBudget`／`budgetCap`、不新增 `CompileError`。要等比放大得重新裁決預算條款 | 要改 → E001 |
| F003 A1 | 法力權重表的具體常數 | 依既有 fold 的顆粒度給出有區分度的小整數表；日後調平衡只改 `manaCost` 內部常數與 `ManaWeightSpec` 的期望值，不動任何簽名 | 接受 |
| F003 A2 | `refusalCode`／`pm_cast_ex` 的錯誤碼分類本輪不分辨兩類 | 本輪不開 boundary/FFI 入口，現有入口永遠產生不出 `ManaExceeded`，改了沒有可測的觀察點。未來接上 FFI 時要一併補 | 接受 |

## 委派品質觀察

編排者在收件時發現、已機械性修正、不影響設計內容的問題：

| 波次 | 觀察 | 處理 |
|---|---|---|
| W1 設計 | F002、F003 兩份文檔都混入簡體字（`对`／`应`／`总`／`层`／`维` 等），違反專案的繁體中文慣例 | 編排者以字元對照表機械轉換並重新正規化為 CRLF；未改動任何設計內容 |
| W1 設計 | 兩份文檔產出時的行尾不一致 | 統一正規化為 CRLF |

編排者另行查證的宣稱：F003 宣稱 `PM_ERR_MANA = -8` 是下一個未用的錯誤碼——打開 `include/particle_magic.h` 與 `bindings/csharp/ParticleMagic.cs` 確認 −1..−7 已用、−8 未用，宣稱成立。

## 階段結果

### 階段四

**W1 設計**（commit `c0f47ea`）：F002、F003 兩份設計文檔完成，皆無阻塞項。

**W1 實作**（序列）

| feature | id | commit | 測試 | 手動 smoke |
|---|---|---|---|---|
| volumetric-sigil | F002 | `13f685f` | 1988 examples / 0 failures（前 1941） | 編排者執行並通過 |
| spell-cost-model | F003 | `13663b3` | 2044 examples / 0 failures（前 1988） | 無此項（純核心閘門） |

**編排者的獨立驗證**（不採信回報，逐項自己跑）

| 檢查 | F002 | F003 |
|---|---|---|
| `cabal build all` / `cabal test` | 0 errors / 1988·0 | 0 errors / 2044·0 |
| 既有 golden 是否被重錄 | 否（只新增 `stacked-sigil.txt`） | 否（18 張全未動） |
| 凍結面 | `Magic/Sigil.hs` 零改動 | header 只有新增行、錯誤碼 −1..−7 未動、33 個 `foreign export` 未增減 |
| 行尾 | 全 CRLF | **四個新 spec 檔是 LF，編排者修正** |
| 簡體字 | 無 | 無 |
| 作者面 | `magic-schema --check` 一致、18 張陣全過 validate | — |

**arch-audit subsys 發現**

| 嚴重度 | 發現 | 建議動作 |
|---|---|---|
| 高 | `design.md` 三處敘述已與程式碼不符：C1.3 只講一個上限值、§C1 下方「編譯錯誤目前只有一種：預算超額」、資料流管線「執行期只檢查一件事：粒子總量是否超過護欄」。F003 加了第二種編譯錯誤與第二道可選閘門 | 由編排者更新這三處（Level 2 文字對帳，不改契約實質） |
| 中 | 本輪觸及三個其他子系統的檔案：host-runtime（`include/particle_magic.h`、`src/ffi/Magic/FFI.hs`、`bindings/csharp/ParticleMagic.cs`、`docs/integration.md`）、boundary-host（`src/boundary/Magic/Codec.hs`）、authoring-engineering（`tools/Schema.hs`、`docs/spell-schema.md`、`docs/spell.schema.json`）。`/subsys-build` 的邊界寫「不跑跨子系統」，但契約卡與批次澄清實際授權了 C ABI 漣漪，而新增陣層級屬性必然要動 codec 與 schema | 開發者裁決：這類「必然連動」要不要在 Level 2 明文寫成 magic-semantics 的擴充成本 |
| 低 | `SigilVolume` 是零欄位型別、schema 上是零屬性物件，於是 `"volume": {"任意鍵": 1}` 會被接受。與既有 codec 行為一致（aeson 不拒未知鍵），但這是第一個「內容完全無意義」的鍵 | 觀察；`docs/spell-schema.md` §8.5 已說明 presence 即開關 |
| 低 | C4.2 的「索引序即繪製序」在多層下是**逐發射器**成立：各層共用同一個 `formEnv`，所以整疊同時長出來，而不是逐層畫完再畫下一層。手動 smoke 確認畫面讀起來仍是「被畫出來的」 | 觀察；若要寫進 C4.2 需開發者同意 |

**契約卡對帳**：F002、F003 兩張卡的「負責模組」「實作的 Level 2 介面」「資料流管線段落」與實際落點相符；兩張卡的「契約補完」小節（批次澄清產物）逐條都在程式碼裡兌現。


**閘門裁決（2026-08-22，開發者）**

| 項目 | 裁決 |
|---|---|
| F002 A1（`SigilVolume` 零欄位純開關） | 接受 |
| F002 A2（節點與中心點不參與堆疊） | **記成 enhancement**，見 [E001](../enhancements/E001-volumetric-density.md) |
| F002 A3（層數公式與 `layerGap = 0.12`） | 接受——手動 smoke 確認讀得出分層又不鬆散 |
| F002 A4（粒子總量不變、密度攤薄） | **記成 enhancement**，見 [E001](../enhancements/E001-volumetric-density.md) |
| F003 A1（法力權重表常數） | 接受 |
| F003 A2（`refusalCode`／`pm_cast_ex` 本輪不分辨兩類） | 接受 |
| 高嚴重度發現：`design.md` 三處敘述漂移 | **當場修正**（C1.3 改為兩道閘門、「編譯錯誤有兩種」、資料流管線的驗證段），純文字對帳，契約實質未變 |
| 中嚴重度發現：跨子系統觸及 | 接受現狀，不另立文檔——新增陣層級屬性必然要動 codec 與 schema，新增 `CompileError` 必然要動 C ABI，兩者都在契約卡與批次澄清裡授權過 |
| 兩條低嚴重度觀察 | 記錄於上表，不動工 |
| 下一步 | **就此停下**。階段五的兩項都在等別的子系統，本輪範圍已做完 |

A2／A4 被判定為 enhancement 而非本輪修正，理由是兩條都會碰到預算護欄（C1.3），而預算條款屬 Level 2 契約——F002 的契約卡與批次澄清都沒有授權改動它。動工前要走 `/enhance-design`。
