---
id: E001
type: enhance
title: volumetric-density
description: 立體陣改為每層全量粒子，節點與中心點一併堆疊
status: done
created: 2026-08-22
updated: 2026-08-22
depends-on: [F002]
related-adr: [adr-0014, adr-0020]
related-feature: [F002]
---

# E001: 立體陣的粒子密度與節點堆疊

> 本文檔原為 `/subsys-build magic-semantics` 階段四閘門（2026-08-22）產出的**待辦登記**；同日經 `/enhance-design` 讀程式碼、與開發者定案 scope 後補完為完整的優化設計。下方「背景」保留當初的閘門記錄。

## 背景

`magic-semantics/F002`（volumetric-sigil，commit `13f685f`）交付了陣的立體堆疊：opt-in 的第五個陣層級屬性 `circleVolume`，層數由槽位佔用導出（`min 5 (max 2 (1 + occCount))`），層次偏移放在每個發射器自己的 `anchorOffset`。

實作期間有兩個判斷是執行者在沒有人可問的情況下自己下的，被如實記進文檔的「待確認假設」（A2、A4），並在閘門攤開給開發者。開發者的裁決是「兩條都值得做，但不在這一輪」——理由是兩條都會碰到預算護欄，而 F002 的契約卡與批次澄清都沒有授權改動它。本輪就是那個「後來」。

## 現況分析

### 現況怎麼運作

陣形發射器全部由 `src/core/Magic/Compile.hs:1062` 的 `formationEmittersFor` 產出，五類來源：

| 來源 | 程式碼位置 | 粒子數來源 | 現況是否堆疊 |
|---|---|---|---|
| 筆畫 `spStrokes` | `Compile.hs:1066` | `sigilPlan` 的 `skCount` | 是，`layeredEmitters` |
| 外圈預覽形狀 `spShapes` | `Compile.hs:1070` | `shapePreviewCount = 64` | 是，`layeredEmitters` |
| 四個核心節點 | `Compile.hs:1073-1076` | 結構常數 `12` | **否**，單層 |
| 中心點 | `Compile.hs:1077` | 結構常數 `16` | **否**，單層 |

層數由 `stackDepth`（`Compile.hs:980`）導出，層次偏移由 `layerAnchor`（`Compile.hs:1007`）以 `layerGap = 0.12` 對稱鋪開。**每層的粒子數由 `perLayerCount`（`Compile.hs:1022`）決定**：

```haskell
perLayerCount total depth arms =
  ((total `div` max 1 depth) `div` max 1 arms) * max 1 arms
```

也就是把單層的配額在各層之間**均分**，再捨到 `skSymmetry` 的倍數。除不盡的餘數直接丟掉、不重分配——所以跨層總和恆 `<=` 原單層總量。這條性質目前被 `test/SigilVolumeStructureSpec.hs:127` 明文釘住（「every stroke's cross-layer sum stays at or under the plan's single-layer count」）。

### 痛點：開了立體，陣反而變稀

拿唯一的立體陣範例 `assets/spells/stacked-sigil.json`（`depth = 5`）實測，對照同一張陣拔掉 `circle.volume` 後的結果：

| | 總粒子 | 發射器 | 陣形筆畫部分 |
|---|---|---|---|
| 關掉 `volume`（單層） | 1464 / 16384 | 10 | 1180 |
| 開啟 `volume`（現況，五層） | **1419** / 16384 | 38 | **1135** |

開了立體，總粒子**比單層還少 45 粒**，陣形筆畫少 45 粒。畫面上是五層各約 1/5 密度的環，不是五層實環。作者的直覺（「開了立體，陣應該更實」）與程式的行為相反。

節點的部分更明顯：`stacked-sigil` 的節點與中心點是那 38 個發射器裡的最後兩個（idx 36 = 節點 12 粒、idx 37 = 中心 16 粒），`anchorOffset` 的 z 全是 0——五層的環中間夾著兩顆扁在中央平面的裝飾點，讀起來像兩個東西疊在一起，不是一個立體的陣。

### 預算的實際位置（重要：不在對外契約上）

- `sigilBudget = 1536`（`src/core/Magic/Sigil.hs:382`）在 `sigilPlan` 內部把筆畫加形狀預覽等比削到上限。它**沒有**被 `magic-boundary` 或 `particle-magic-ffi` 再匯出（全庫只有 `test/SigilPlanSpec.hs`、`test/SigilWiringSpec.hs` 引用），因此是 Level 3 的核心內部常數，不是 Level 2 的 C1.3。
- 真正的 Level 2 閘門是 `budgetCap = 16384`（`Compile.hs:479`），在 `compile`（`Compile.hs:653`）與 `compileMany`（`Compile.hs:689`）對總量檢查，超過回 `BudgetExceeded !Int !Int`。這一條連同 C ABI 的錯誤碼本輪**完全不動**。
- 節點的 12 與中心的 16 是 spec 0006 §4.4 的結構常數，刻意在 `sigilBudget` 之外（ADR-0014 記帳：「≤ 64 粒」）。

### 與架構文件的一致性

`design.md` 的 C4.2 承諾「筆畫帶沿法線的層次偏移」、C1.3 承諾「粒子總量對一個固定上限檢查」——現況與兩者都相符，本輪也都不改。現況與文件之間**沒有**不一致。

## Scope（涵蓋範圍）

2026-08-22 與開發者逐題定案：

**動**

- 只動 `magic-semantics` 一個子系統，只動 `src/core/Magic/Compile.hs` 的 `formationEmittersFor` 區塊（層數與偏移的既有機制照用）。
- `src/core/Magic/Sigil.hs` 只改 `sigilBudget` 的 haddock 語意敘述（「一個陣的預算」→「一層的預算」），**數值與 `sigilPlan` 的程式碼一行不動**。
- 測試：反轉 `test/SigilVolumeStructureSpec.hs` 的「只攤薄不放大」那一條，新增本輪的驗收測試檔。
- golden：預期只重錄 `test/golden/perf-0010/stacked-sigil.txt` 一張。

**明確不動**

- **`budgetCap = 16384` 與 C1.3**：上限值、檢查點、錯誤語意全不變。
- **不新增 `CompileError` 建構子**，因此 `include/particle_magic.h`、`bindings/csharp/ParticleMagic.cs`、31 個 C 匯出符號與所有錯誤碼一個都不動。
- **`sigilBudget` 的數值 1536 與 `sigilPlan` 的削減演算法**：不抬高、不改分配方式（抬高會連動重錄所有單層陣的 golden，影響面遠大於本輪）。
- **`hashCircle`**：堆疊不進摘要是 ADR-0014 D3 的直接後果，本輪兩項都不改變這一點。
- **`circleVolume` 的 JSON 形狀**（F002 A1）、**層數公式與 `layerGap`**（F002 A3）：兩條各自是獨立的待辦／已接受假設，不納入。
- **節點公轉**（功能規劃 #2 node-orbit）：本輪只讓節點沿法線堆疊，不碰它們的運動。

**對外契約**：維持相容。C1.3、C4.2、C3.2 的條文與 C ABI 皆不變動，`design.md` 本輪**不需要更新**。

**被排除的「順便改」**：抬高 `sigilBudget` 讓單層陣也更密（討論中冒出，建議日後另開 E 文檔，因為它要重錄全部單層 golden）。

## 改善目標

| # | 驗收標準 | 量化 |
|---|---|---|
| G1 | 每層拿到單層的完整配額 | 開啟 `volume` 時，每一筆畫的**每一層**發射器 `emCount` 逐一等於 `sigilPlan` 該筆畫的 `skCount`（嚴格等式，不是近似）；形狀預覽同理等於 64 |
| G2 | 立體陣比單層陣更實 | `stacked-sigil.json` 的 `spellBudget` 由 **1419 → ≥ 5900**；其陣形筆畫部分由 1135 → 5900（= 1180 × 5） |
| G3 | 節點與中心點跟著堆 | 開啟 `volume` 時，每個被填的節點槽產出 `depth` 顆發射器、每顆 12 粒；中心槽產出 `depth` 顆、每顆 16 粒；層次偏移與筆畫共用同一個 `depth` 與同一組 z 座標 |
| G4 | 零漣漪律不退化 | 未開 `volume` 的陣輸出**逐位元不變**：`test/golden/` 底下除 `perf-0010/stacked-sigil.txt` 外一張都不重錄（以 `git status` 佐證） |
| G5 | 總量有明確上界 | 任何陣的陣形總量 `<= (sigilBudget + 64) * 5 = 8000`；超過 `budgetCap` 時仍走既有的 `BudgetExceeded`，不新增錯誤路徑 |
| G6 | 全案綠燈 | `cabal build all` 與 `cabal test` 全綠，examples 數不低於交付前基準 |

## 相依性

- **`depends-on: [F002]`**：本輪改的 `perLayerCount`／`layeredEmitters`／`stackDepth`／`layerAnchor` 全部是 F002 交付的程式碼，`circleVolume` 這個陣層級屬性也是。F002 `status: done`，不阻塞動工。
- **`related-adr: [adr-0014, adr-0020]`**：ADR-0014 的記帳段落寫著「`sigilBudget = 1536` 只涵蓋 plan」——本輪把它重讀為**每層**的上限，跨層上界成為 `depth × sigilBudget`；那一行是記帳而非 D 編號的凍結決策，且 `sigilBudget` 未跨出核心，故不觸發「凍結介面需 ADR」。ADR-0020 記帳寫「中心不動本來就是設計要的視覺定錨點」——那句話講的是**自轉**（中心不參與繞面心公轉），本輪讓中心沿法線排成中軸柱不使它旋轉，中軸仍是那個定錨點，兩者不衝突。
- **可平行**：本輪只碰 `Magic/Compile.hs` 與 `Magic/Sigil.hs` 的註解。與任何不同時改這兩個檔案的任務可平行；撰寫時子系統內無其他進行中任務。
- **不阻塞任何人**：C ABI、boundary、render-shell 完全不在改動面上。

## 改善方案

### S1 每層全量（對應 F002 A4）

`layeredEmitters` 每一層直接使用筆畫自己的 `total`，不再除以 `depth`：

- 移除 `perLayerCount`（唯一呼叫端就是 `layeredEmitters`），`layeredEmitters` 的 `arms` 參數隨之無用，簽名由 `SpawnPattern -> Int -> Int -> [EmitterSpec]` 收為 `SpawnPattern -> Int -> [EmitterSpec]`。
- 兩處呼叫端（`Compile.hs:1066`、`1070`）去掉最後一個引數。
- 更新 `sigilBudget`（`Sigil.hs:379-383`）與 `formationEmittersFor` 的 haddock：預算的結算單位由「一個陣」改為「一層」。

**零漣漪律因此變得更強，不是更弱**：現況的 `depth = 1` 恆等式要靠「`total` 已經是 `arms` 的倍數」這個前提（`perLayerCount total 1 arms == total` 只在該前提下成立）；改完之後 `depth = 1` 那一層拿到的就是 `total` 本身，恆等式無前提成立，`layerAnchor 1 0 == originAnchor` 那一半原本就無前提。

### S2 節點與中心點入列（對應 F002 A2）

`nodeSlotEmitter` 與 `centerSlotEmitter` 改為每層各產出一顆發射器，**每層維持結構常數不攤分**（節點 12、中心 16）：

- 節點的層次偏移**加**在它自己的偏移上：`anchorOffset = offset + V3 0 0 (layerGap * (fromIntegral k - 0.5 * (fromIntegral depth - 1)))`。`Magic.Types` 已有 `instance Num V3`（`Types.hs:44`），不需要新的 helper。
- 中心點的基底就是 `originAnchor`，`layerAnchor depth k` 可直接使用，結果是沿中軸的一根等距點柱。
- 節點／中心與筆畫**共用同一個 `stackDepth circle`**——陣是一個東西，不該有兩套層數。
- `depth = 1` 時 `layerGap * (0 - 0) = 0`，兩者都退回現況的 anchor，逐位元不變。

節點與中心的跨層上界：`(4 * 12 + 16) * 5 = 320` 粒，連同筆畫的 `1536 * 5 = 7680` 得到 G5 的 8000。

### S3 預算與超額路徑

不新增任何機制：放大後的總量照舊經 `compile` 的 `totalCount > budgetCap` 閘門，超過就是既有的 `BudgetExceeded requested cap`。

**本輪唯一的相容性代價**，明白記在這裡：一張既有的、已經開了 `volume` 的陣，若施放粒子夠多，可能從「編譯成功」變成 `BudgetExceeded`。這在現況不可能發生（現況開 `volume` 只會讓總量變小）。代價可接受的理由：`circleVolume` 是 2026-08-22 才交付的 opt-in 屬性，全庫只有一張範例用它；失敗是**編譯期**的、明確的、帶「需求量／上限」數字的，不是執行期的靜默退化。自動降層與自動攤薄兩案被否決——它們讓「層數由結構導出」不再純由結構決定，作者看不出為什麼陣變薄了。

### S4 golden 與文件

- 重錄 `test/golden/perf-0010/stacked-sigil.txt`（粒子數變了，取樣摘要必然變）。以 `git status` 證明這是**唯一**變更的 golden。
- 檢查 `docs/spell-schema.md` 對 `volume` 的敘述是否提到粒子密度；有就更新，沒有就不動（schema 形狀不變，`magic-schema -- --check` 應維持通過）。

## 使用到的既有串接介面

| 介面（含完整簽名） | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `formationEmittersFor :: Circle -> Seconds -> Seconds -> Element -> [EmitterSpec]` | `src/core/Magic/Compile.hs:1062` | F002 | 本輪唯一的改動點 |
| `stackDepth :: Circle -> Int` | `src/core/Magic/Compile.hs:980` | F002 | 層數，原樣沿用；節點／中心共用同一個值 |
| `layerAnchor :: Int -> Int -> Anchor` | `src/core/Magic/Compile.hs:1007` | F002 | 筆畫與中心點的層次 anchor，原樣沿用 |
| `layerGap :: Float` | `src/core/Magic/Compile.hs:999` | F002 | 節點偏移相加時取用同一個間距 |
| `perLayerCount :: Int -> Int -> Int -> Int` | `src/core/Magic/Compile.hs:1022` | F002 | **本輪移除** |
| `originAnchor :: Anchor` | `src/core/Magic/Compile.hs:817` | - | 節點／中心 `depth = 1` 的退化目標 |
| `sigilPlan :: Circle -> SigilPlan` | `src/core/Magic/Sigil.hs:457` | - | 筆畫與形狀的配額來源，程式碼不動 |
| `sigilBudget :: Int` | `src/core/Magic/Sigil.hs:382` | - | 只改 haddock 的結算單位敘述 |
| `shapePreviewCount :: Int` | `src/core/Magic/Sigil.hs:391` | - | 形狀預覽的 64，不動 |
| `budgetCap :: Int` | `src/core/Magic/Compile.hs:479` | - | 總量閘門，不動 |
| `BudgetExceeded !Int !Int`（`data CompileError`） | `src/core/Magic/Compile.hs:456-458` | - | 超額路徑，不新增建構子 |
| `instance Num V3`（`data V3 = V3 !Float !Float !Float`） | `src/core/Magic/Types.hs:37, 44` | - | 節點偏移與層次偏移相加 |

## 介面變動

**公開介面（`magic-core` 匯出面）零變動。** `stackDepth`、`layerAnchor`、`layerGap`、`perLayerCount`、`layeredEmitters` 都不在 `module Magic.Compile ( ... )` 的匯出清單裡，`sigilBudget` 不在 `magic-boundary` 或 `particle-magic-ffi` 的傳遞路徑上。

| 項目 | 變動 | 受影響呼叫端 |
|---|---|---|
| `perLayerCount` | **移除**（內部） | `layeredEmitters` 一處，同批改掉 |
| `layeredEmitters` | 簽名去掉 `arms`（內部，`where` 綁定） | `formationEmittersFor` 內兩處 |
| `nodeSlotEmitter`／`centerSlotEmitter` | 回傳由單元素列表改為 `depth` 元素列表（內部，`where` 綁定） | `formationEmittersFor` 內五處，型別不變 |
| `sigilBudget` | 數值與型別不變，**語意敘述**改為「一層的預算」 | 無程式碼呼叫端；`test/SigilPlanSpec.hs` 的斷言仍成立（它斷言的是 `sigilPlan` 本身，不是發射器） |

**可觀測的行為變動**（不是介面，但要記）：

1. 開啟 `volume` 的陣，`spellBudget` 與 `budgetPerEmitter` 的數字上升；`stacked-sigil.json` 由 1419 升至約 6300。
2. 開啟 `volume` 的陣，`spellEmitters` 的長度上升（節點與中心各多 `depth - 1` 顆）。
3. 開啟 `volume` 的陣，空間包絡沿法線再加寬一點（節點與中心現在也佔法線方向的厚度）。C3.2 的**逐位元凍結面不受影響**：`test/SpaceBoundsSpec.hs:179` 已把 `stacked-sigil.json` 排除在 172 列凍結值之外，未開 `volume` 的陣一列都不動。
4. 開啟 `volume` 且施放粒子多的陣，可能新撞上 `BudgetExceeded`（見 S3）。

**未開 `volume` 的陣：以上四條全部不適用，輸出逐位元不變。**

## TodoList

- [x] T1: 鎖定基準線——記下改動前 `cabal test` 的 examples 數與全綠狀態；新增 `test/SigilVolumeAmplifySpec.hs`，先寫零漣漪回歸段（未開 `volume` 的陣：發射器數、逐發射器 `emCount` 與 `emAnchor` 與現況逐一相等），此時應為綠  `dep: -`
- [x] T2: 每層全量——移除 `perLayerCount`，`layeredEmitters` 每層改用 `total` 並去掉 `arms` 參數；更新 `sigilBudget` 與 `formationEmittersFor` 的 haddock 結算單位敘述  `dep: T1`
- [x] T3: 反轉舊律——改寫 `test/SigilVolumeStructureSpec.hs:126-140` 的「stacking only thins, never inflates」為「每筆畫的跨層總和 = 單層配額 × depth」  `dep: T2`
- [x] T4: 節點堆疊——`nodeSlotEmitter` 每層一顆、每顆 12 粒，層次偏移加在自己的 `anchorOffset` 上  `dep: T2`
- [x] T5: 中心堆疊——`centerSlotEmitter` 每層一顆、每顆 16 粒，沿中軸以 `layerAnchor` 鋪開  `dep: T2`
- [x] T6: 上界與超額——補「任何陣的陣形總量 `<= (sigilBudget + 64) * 5`」的性質測試，並確認超額仍回既有的 `BudgetExceeded`  `dep: T4, T5`
- [x] T7: golden 與文件——重錄 `test/golden/perf-0010/stacked-sigil.txt`，以 `git status` 證明其餘 golden 未動；檢查 `docs/spell-schema.md` 的 `volume` 敘述並確認 `magic-schema -- --check` 通過  `dep: T3, T6`
- [x] T8: 手動 smoke——以 demo 視窗確認立體陣比單層更實、節點與中心點跟著堆成柱，結果記入「實作備註」  `dep: T7`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|---|---|---|
| T1 | `SigilVolumeAmplifySpec`「零漣漪：未開 `volume` 的陣，發射器數與逐發射器的 count／anchor 不因本輪改動」 | 保護現有行為的回歸測試，先寫先綠；對應 G4 |
| T2 | `SigilVolumeAmplifySpec`「每一層的每一筆畫拿到 `sigilPlan` 的完整 `skCount`，形狀預覽拿到完整 64」 | 對應 G1 |
| T3 | `SigilVolumeStructureSpec`（改寫）「每筆畫的跨層總和 = 單層配額 × `depth`」 | 舊律的反轉，嚴格等式；對應 G1、G2 |
| T4 | `SigilVolumeAmplifySpec`「每個被填的節點槽產出 `depth` 顆發射器，每顆 12 粒，z 座標與筆畫層同一組」 | 對應 G3 |
| T5 | `SigilVolumeAmplifySpec`「中心槽產出 `depth` 顆發射器，每顆 16 粒，沿中軸等距且對稱於面原點」 | 對應 G3 |
| T6 | `SigilVolumeAmplifySpec`「陣形總量上界 `<= (sigilBudget + 64) * 5`（對任意產生的陣）；超額的陣仍回 `BudgetExceeded`，建構子與 cap 值不變」 | 性質測試 + 既有錯誤路徑；對應 G5 |
| T7 | 既有 `PerfGoldenSpec`／`Acceptance21Spec`／`SpaceBoundsSpec`／`JsonSchemaSpec` 重跑全綠 | `stacked-sigil.txt` 是唯一變更的 golden；對應 G4、G6 |
| T8 | 手動 smoke（非自動化，結果記入「實作備註」） | 對應 G2 的視覺面 |

## 實作備註

實作方式與「改善方案」逐項相符，公開介面無偏離。

### 量化結果（對照「改善目標」）

| # | 目標 | 結果 |
|---|---|---|
| G1 | 每層拿到完整配額 | 達成。T2/T3 以嚴格等式驗證：每層 `emCount == skCount sk`（形狀為 64），跨層總和 `== skCount sk * depth` |
| G2 | `stacked-sigil` 的 `spellBudget` 1419 → ≥ 5900 | 達成，**1419 → 6296**（`magic-inspect` 實測）。拆解：陣形 6040（筆畫與形狀 1180 × 5＝5900、節點 12 × 5＝60、中心 16 × 5＝80）+ 施放 256 |
| G3 | 節點與中心跟著堆 | 達成。發射器數 38 → 46（節點與中心各由 1 顆變 5 顆）；T4/T5 驗證每層維持 12／16，且 z 座標集合與筆畫層**逐一相等** |
| G4 | 零漣漪律不退化 | 達成。`git status` 顯示 `test/golden/` 底下只有 `perf-0010/stacked-sigil.txt` 一張變更；T1 的五條回歸斷言在改動前先跑綠，改動後仍綠 |
| G5 | 上界 `(sigilBudget + 64) * 5 = 8000` | 達成。T6 對 `genAnyCircle` 產生的任意陣做性質測試（100 例），全數落在界內或以既有的 `BudgetExceeded`（cap 值仍是 `budgetCap`）被拒 |
| G6 | 全案綠燈 | 達成。`cabal build all` 成功，`cabal test` **2066 examples / 0 failures**（交付前基準 2048 / 0，新增 18 條） |

### 與設計的差異

- **`layeredEmitters` 的收斂方式**：設計寫「簽名去掉 `arms`」。實作把它拆成 `layeredColumn offset spawn count`（帶面內偏移的通用版）與 `layeredEmitters = layeredColumn (V3 0 0 0)`（面原點版），讓筆畫、形狀、節點、中心四類共用同一段建構程式碼。屬 Level 3 實作自主權，對外行為與設計一致：`offset == 0` 時兩者逐位元相同。
- 其餘與設計逐字相符。`Magic/Sigil.hs` 只動 `sigilBudget` 的 haddock，`sigilPlan` 與數值 1536 未動（`git diff` 確認）。

### 手動 smoke（T8，2026-08-22）

以 demo 視窗實跑，`aaa-` 前綴讓待測陣成為啟動時顯示的那張，事後刪除。同一張 `stacked-sigil` 的立體版與拔掉 `volume` 的單層版各跑一次，預設 3/4 視角（`cam: r 8.7 az 45 el 13`），取畫陣完成、施放前的同一時刻對照：

| 版本 | HUD `age` | HUD `particles` | 畫面 |
|---|---|---|---|
| 單層（`aaa-flat`） | 1.75s | **1208** | 地面上一片扁平的陣，環與環都在同一個平面 |
| 立體（`aaa-stacked`） | 1.72s | **6040** | 多層平行環組成的**鼓狀體**，每一層本身的密度與單層版的環相當，不是攤薄後的稀環 |

比值 6040 / 1208 ≈ 5.0，與 `depth = 5`、每層全量的設計一致；1208 也正好是 1180 + 12 + 16，證實單層路徑一顆粒子都沒動。**E001 要修的那個反直覺（開了立體反而更稀）在畫面上已消失。**

節點與中心點堆成柱這一點，在 3/4 視角下被密集的環遮住、目視無法單獨判讀，因此不以畫面主張；它由 T4／T5 的自動測試逐條斷言（每層 12／16 顆、四個面內方位各自成一柱、z 座標集合與筆畫層相等）。

（附記：立體版的連拍在畫陣階段之後有數張被其他視窗蓋住而無效，上表只採用有效的畫陣階段影格；施放階段不在本輪的驗收標準內。）
