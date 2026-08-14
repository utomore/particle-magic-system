# 路線圖與完整度盤點

> 版本：1.3（2026-08-15，第一波 spec 0010／0011／0013 三份同時驗收後更新 §1／§2／§3／§5／§6；1.1 為 spec 0010–0014 設計定案後的修訂，1.0 為 spec 0001–0009 全數交付後的第一次全面盤點）
> 狀態：現況快照＋候選排序。每次 func-spec 驗收後更新本文。
> 相關文件：[architecture.md](architecture.md)（系統長什麼樣）、[SKILL.md](../SKILL.md)（怎麼工作）、[integration.md](integration.md)（宿主怎麼接）

architecture 回答「系統長什麼樣、為什麼」，func-spec 回答「這一輪具體怎麼蓋」，本文回答第三個問題：**還差什麼、下一輪該蓋哪一個**。

本文不做新決策。內容全部由既有文件盤點而來——各 spec 的 §9 非目標、§10 驗收紀錄、architecture §7/§8。真正的取捨仍然寫進 ADR，本文只負責讓「欠了什麼」在一個地方看得見。

---

## 1. 現況快照（2026-08-15）

- **已交付**：func-spec 0001–0011 與 **0013** 全數狀態「已完成」；ADR 0001–0011。第一波（0010 效能 ‖ 0011 宿主整合面 ‖ 0013 視覺）三份由三個 session 平行實作、同時驗收，一次整合進 main。
- **驗證**：`cabal build all` 綠（含 exe、bench、foreign-library）；`cabal test` 綠。0007／0008／0009 曾以同一模式三方平行；本輪 0010／0011／0013 再次驗證零檔案交集切分成立——三份 spec 的 §0.2 盤點事後全部正確（0010 未動 `src/ffi`／`include`／`app/*`，0013 只動 `app/*`）。
- **0010 交付的效能位置**（詳見其 §9.2）：4096 粒每幀純 CPU **0.73 ms → 0.27 ms**；取樣常數因子 **161 → 65 ns/粒**；`depthOrder` @4096 快 **10×**；合成 100 000 粒取樣 **6.5 ms**（60 fps 預算的 39%）。粒子上限仍是 4096——本輪明文不改值（§4.6 修正 1），提升落在 0012。

| 產物 | 指令 | 對象 |
|---|---|---|
| demo 執行檔 | `cabal run particle-magic` | 開發者自己看：3D 透視／2D 側視／2D 俯視即時切換、JSON 熱重載、HUD |
| Haskell 公開子庫 | `build-depends: particle-magic:magic-boundary` | Haskell 宿主 |
| C ABI 共享庫 | `cabal build particle-magic-ffi` | Unity／Godot／C++／任何能載入 `.dll`／`.so` 的宿主 |

第三種的存在是本專案「庫必須完整、繪圖在庫外」這條原則的**可執行證明**：`examples/c/main.c` 是一個 150 行、不畫任何東西的 C 宿主，它的逐幀輸出與 Haskell 路徑逐行相同。0011 之後，第三種也拿得到 2D 投影與 painter 排序，並附 C# 參考綁定（`bindings/csharp/`）與 Unity 範例（`examples/unity/`）。

---

## 2. 完整度：先問「對什麼而言」

單一個百分比會騙人，因為這個專案同時是三件事，而三件事的完成度差很多。

| 這是在問…… | 完整度 | 一句話依據 |
|---|---|---|
| **A. 架構論證**——「Circle as Data」這個賭注成不成立 | **≈ 85%** | 五步解釋器 fold、JSON schema v1、決定論、換投影不改核心、換宿主語言不改核心——全部從宣稱變成了測試。剩下的 15% 是「多陣疊加」這個 Init.md 明列卻唯一未落地的語意 |
| **B. 可被外部遊戲實際使用的庫** | **≈ 60%** | 兩種消費模式都已凍結合約並可用；0010 後速度已到 10k–100k 檔次，但**護欄仍是 4096**（值的提升在 0012），單陣、無多執行緒保證、無語言包裝層、無版本 tag |
| **C. 產品級特效系統** | **≈ 40%** | 觀察面已補齊（0013：3D 深度排序、相機操控、俯視深度色調）、熱路徑已優化（0010）；但仍只有方形 quad、無貼圖／拖尾／軟粒子、無作者工具 |

### 分維度明細

| 維度 | 完整度 | 已有 | 缺口 |
|---|---|---|---|
| 架構與純度紀律 | **95%** | 三環依賴、`BoundarySpec` 機械守護、核心零 IO、依賴白名單 | — |
| 魔法語意（表達力） | **70%** | Init.md 參數對照表 11 列落地 10 列；四階段生命週期、力場層、Expr 子系統 | 多陣合成（唯一未落地列）；各 sum type 的建構子數量仍是 POC 級（`FaceShape` 4 種、`ForceField` 3 種、`Element` 少數、`BillboardShape` 1 種） |
| 對外介面 | **90%** | Haskell public sublibrary＋C ABI header 兩份凍結合約；決定論跨界為可測等價律；投影／painter 排序／上限查詢已上 C ABI（0011），C# 參考綁定受契約測試守護且在 Unity 6000.5.7f1 實測通過 | 無多 spell 聚合 API；無 release tag／Hackage；GDScript／C++ 包裝層 |
| 效能 | **70%** | 0010：熱路徑端到端 unboxed（count-then-fill、`FieldState` SoA、in-place introsort）、結構化 `ParticleBudget`、發射器時間窗剔除、Expr 常數摺疊、per-emitter 基底提升；10k–100k 已實測（100k 取樣 6.5 ms） | 護欄值 4096 未動（0012 S1）；architecture §7 六項手段中「緩衝重用」在純介面下經評估不做（0010 §9.4-10）、architecture §8.2 的 Expr bytecode 與多執行緒取樣仍未做 |
| 視覺表現力 | **50%** | 兩個投影後端、blend 生效、顏色曲線、painter 排序（2D）；0013：3D alpha batch 深度排序、軌道／dolly 相機、2D 平移／游標定錨縮放／resize 適配、俯視深度色調 | 只有方形 quad；無貼圖／拖尾／軟粒子；俯視可讀性只解到第一階（進階的壓平比例／輪廓強調仍欠，0013 §8-4） |
| 作者流程（工具） | **15%** | JSON 熱重載、載入錯誤上屏（含行列位置）、9 個範例陣 | 無編輯器、無給非工程作者的 schema 說明、無驗證 CLI、spell 清單啟動時定格 |
| 工程紀律（測試／文件） | **95%** | Todo↔測試 1:1、逐位元相容律、契約守護測試（cabal／header／`.def`／C# 綁定四份文本）、11 ADR／10 spec／706 examples | 無 CI；只有 win64 實測過 |

---

## 3. 未落地盤點（依記帳來源）

每一條都在某份 spec 的 §9 裡有主。這是欠款總表，不是願望清單。

### 3.1 效能（0010 已結清大部分；下表為結清後的餘額）

| 項目 | 記帳於 | 0010 之後 |
|---|---|---|
| `ParticleBuffer` 緩衝重用（`ST` 內部、對外仍純） | 0005 §9、architecture §7 | **改判：純介面下不做**。`observeSpell` 回傳的 buffer 是宿主可長期持有的純值，跨幀重寫會偷改上一幀（違反 ADR-0007）。正解是「每幀恰好六次 exact-size 配置、零中介」，0010 已落地；真正的 mutable 重用需要不同的 API 合約，且 §9.2 的量測顯示配置不是瓶頸（0010 §9.4-10） |
| `fromParticles` 的 list 中介消除 | 0005 §9 | ✅ 0010 S2（`buildBuffer` count-then-fill；`fromParticles` 降為相容薄包裝） |
| 結構化 `ParticleBudget` 取代裸 `spellBudget`／`budgetCap` | 0004 §9、0006 §9、architecture §4.4 | ✅ 0010 S7（`ParticleBudget`＋`spellBudgetPlan`；`spellBudget` 保留為總和） |
| 發射器層級剔除（Expr 靜態範圍分析） | 0007 §9、architecture §7 | ✅ 0010 S3（時間窗剔除，`aliveRanges`）＋S7（`emitterBounds` 的區間算術 AABB）。**視錐剔除本體仍是宿主責任**，核心只交包絡（0010 §8-3） |
| `FieldState` SoA 化＋帶場 bench | 0007 §9、§4.7 明文不凍結 | ✅ 0010 S4＋S8（表徵**仍不凍結**） |
| `depthOrder` 的高效排序（現為 `sortOn` 產生 boxed list） | 0008 §9-6 | ✅ 0010 S5（in-place introsort，@4096 快 10×） |
| 3D 路徑的深度排序 | 0005 §9、0008 §9-1 | ✅ **0013 S1 交付**（`App.Render.Order.viewOrder`，`app/*` staging 層；該處以 `sortOn` 起步，若日後成為熱點可套 0010 S5 的 in-place introsort，記在 0013 §8-6） |
| Expr 求值加速（SPECIALIZE → 常數摺疊 → bytecode） | architecture §8.2 | 第一階 ✅（0010 S6：`foldConstants`＋`INLINE`/`INLINABLE`）；**bytecode／共同子式消去未做**（0010 §8-4） |
| 10k–100k 吞吐 | architecture §7 目標 | ✅ 已實測（0010 §9.2）：10k = 0.65 ms、50k = 3.1 ms、100k = 6.5 ms（60 fps 預算的 3.9%／19%／39%）。**護欄值仍是 4096** |
| 多執行緒取樣（`-threaded` 平行 sample） | 0010 §8-6 | 未做——先把單執行緒常數因子吃完，已吃到 65 ns/粒 |

**尚未處理的結構性問題**：`4096` 這個數字目前有三份拷貝——核心的 `Magic.Compile.budgetCap`、demo 的 `App.Render.Raylib3D.gpuCapacity`、C 合約的 `PM_MAX_PARTICLES`，且 `test/FFIContractSpec.hs` 把三者釘成相等（§4.6 修正 1）。0010 因此明文不改值，只把它**第一次經公開面匯出**為 `Magic.Interface.maxSpellParticles`（值仍 4096）——0011 把 `pm_max_particles` 接到這裡並把釘選改寫為查詢鏡射律，0012 S1 才動值。0010 §9.2 已給出選值建議：**32 768–65 536**。

### 3.2 語意

| 項目 | 記帳於 |
|---|---|
| 多陣合成（`CompiledSpell` 的 `Semigroup`、`PhasePlan` 合併律、預算超額的 `Either`） | 0006 §9、architecture §6 對照表唯一的「未落地」列 |
| 全域粒子配額與多 `ActiveSpell` 緩衝管理 | architecture §8.4 |
| `Anchor` 的玩家面 JSON 控制 | 0006 §9 |
| 陣形旋轉／動態陣形動畫 | 0006 §9 |
| Expr 驅動的時變場參數（第四種時間掛載點） | 0007 §9 |
| 施法者相對座標系的場 | 0007 §9 |
| 場作用於 Drawing／Converging 相位 | ADR-0010 D6（使用者裁決不做） |
| 可調 Dissipating／全域消散拖尾 | 0006 §9 |

### 3.3 介面／宿主

| 項目 | 記帳於 | 備註 |
|---|---|---|
| ~~`pm_project`／`pm_depth_order` 上 C ABI~~ | 0009 §9-1 | ✅ **0011 交付** |
| 多 spell 聚合／全域配額 FFI API | 0009 §9-7、0011 §8-2 | 依賴 §3.2 的多陣合成（0012） |
| GDScript／C++ 包裝層 | 0009 §9-6、0011 §8-3 | C# 已有參考實作（0011 S4）；其餘等真實宿主需求 |
| ~~C# 綁定在 Unity Editor 的實測~~ | 0011 §9.3 | ✅ Unity 6000.5.7f1 batchmode 實測 27 PASS／0 FAIL；`examples/unity/PmSmoke.cs` 可一鍵複驗 |
| Unity Editor 的「二次 Play」與視覺／GC 觀察 | 0011 §9.3 | 批次模式驗不到（每次新 process）；README §8 為人眼 checklist |
| 多執行緒安全／內部鎖 | 0009 §9-2、0011 §8-4 | 等真實宿主需求 |
| 熱重載 FFI API | 0009 §9-5、0011 §8-5 | 政策已定：重載＝重施法，宿主自行 `pm_cast` |
| ~~座標系手性未見於任何文件~~ | §4.4 | ✅ **0011 寫進 header**（哨兵 `right-handed`，契約測試守護） |
| ~~`pbColor` 的位元組序未寫進 C header~~ | §4.4 | ✅ **0011 寫進 header**（哨兵 `0xRRGGBBAA`，附拆包示例） |
| 上限提升（4096 → 量測值） | 0011 §8-1 → 0012 S1 | 管道已鋪：查詢鏡射律使核心改值時 header 零觸碰 |

### 3.4 視覺

| 項目 | 記帳於 |
|---|---|
| ~~俯視深度重疊的可讀性解~~ 第一解（深度色調）**已交付 0013**；進階解（壓平比例、輪廓強調）仍欠 | 0008 §9-8、architecture §8.6、0013 §8-4 |
| `BillboardShape` 新建構子（貼圖、拉伸 billboard） | 0005 §9、0013 §8-1（明文為「動核心的那半」，本輪不做） |
| `rbShape` 差異化渲染 | 0008 §9-5、0013 §8-1 |
| ~~2D 相機平移／縮放、視窗 resize 適配~~ **已交付 0013** | 0008 §9-3 |
| ~~3D 相機操控（軌道／縮放）~~ **已交付 0013** | 0005 §9 |
| 拖尾／軟粒子／後處理 | 0013 §8-3（產品級視覺，維度 C） |
| 相機動畫／過場、慣性阻尼 | 0013 §8-5 |

### 3.5 系統／流程

| 項目 | 記帳於 |
|---|---|
| fsnotify、spell 清單熱掃描（現在啟動時定格） | 0005 §9、ADR-0005 既定延後 |
| CI（目前全靠本機 `cabal test`） | 未記帳 |
| release tag／版本發布流程 | 未記帳 |

---

## 4. 候選 func-spec 與排序

### 4.1 候選一覽

| 候選 | 主題 | 主要檔案 | 依賴 |
|---|---|---|---|
| **A** | **效能與粒子預算治理**（10k–100k） | `Buffer`／`Analytic`／`Field`／`Compile`／`Interface`／`bench` | 無（動工前提「0005 量測基線」已備） |
| **B** | **宿主整合面**（投影上 C ABI＋參考綁定） | `src/ffi`／`include`／`examples`／新 `bindings/` | 無（0008 完成後解鎖） |
| **C** | **多陣合成與場景層** | `Compile`／`Interface`＋新聚合型別 | 建議在 A 之後（全域配額要靠 A 的 `ParticleBudget` 表達） |
| **D** | **視覺表現力** | `app/*`（＋若動 `BillboardShape` 則含 `Compile`） | 無（限縮在 `app/*` 時） |
| **E** | **作者工具**（驗證 CLI、schema 說明、清單熱掃） | 新 exe／`Codec` | 無 |

### 4.2 為什麼建議 **A（效能）作為 0010 主線**

1. **它是被指名最多次的一筆**：0002、0004、0005、0006、0007、0008 六份 spec 的 §9 都把東西記到「效能 spec」名下。這個名字已經被欠了六輪。
2. **它決定 B 這件事的成敗**：架構論證（完整度 A ≈ 85%）已經很高，可用的庫（B ≈ 55%）低在哪裡？一半低在 4096。宿主接得上、但只能放 4096 顆粒子的庫，離「可用」還有距離。
3. **動工門檻已經到位**：0005 交付的 bench 基線就是為了這一輪存在的，這是唯一一份「前置條件早就備好、只是還沒動工」的候選。
4. **它必須先於任何綁定層被凍結**：每個宿主綁定都會把 `PM_MAX_PARTICLES` 這個數字烤進去。先做綁定再改上限＝破壞既有宿主。

**A 會撞到的一個 ABI 問題，以及乾淨的解**：提高上限意味著 `PM_MAX_PARTICLES` 這個常數的值要變，而 header 是「只加不改」的凍結合約——改常數值是破壞性變更。乾淨解是**新增一個執行期查詢** `int pm_max_particles(void)`，把 header 常數降級為「ABI 第 1 代編譯時的值」，宿主改用查詢結果配置緩衝。這是純增補，完全符合 add-only 規則。

值得注意的是：**這個新匯出屬於 B 的檔案範圍，而它的正確性不依賴 A 做完**——現在加也對（回傳 4096），A 改了核心上限之後它自動回傳新值，header 一個字都不用再動。這讓 A 與 B 可以真正平行：B 先把查詢管道鋪好，A 只管改核心的數字。

### 4.3 為什麼 B 可以與 A **平行**（SKILL.md 規則 4）

| | A 的檔案 | B 的檔案 |
|---|---|---|
| 核心 | `src/core/Magic/{Compile,Particle/*}.hs` | 零觸碰 |
| 邊界 | `src/boundary/Magic/Interface.hs` | 零觸碰 |
| FFI | 零觸碰 | `src/ffi/Magic/FFI.hs`、`include/particle_magic.h` |
| 新目錄 | — | `bindings/csharp/`、`examples/unity/` |
| 殼層 | `app/App/Render/Raylib3D.hs`（`gpuCapacity`） | 零觸碰 |
| 共用 | cabal（`magic-core`／test 行）、SKILL.md（索引列） | cabal（foreign-library／test 行）、SKILL.md（索引列） |

交集為空，只有 cabal 與 SKILL.md 的**不同行**——與 0007／0008／0009 那一輪同款的聯集合併。**A 與 B 可由兩個 session 同時認領。**

B 的具體交付面：`pm_project`／`pm_depth_order`／`pm_max_particles` 三個純增補匯出（`FFIContractSpec` 自動守護 header↔export 一致）、C# 參考綁定與 Unity 最小範例（比照 `examples/c/main.c` 的「手動 smoke」定位）、以及把 [integration.md](integration.md) 裡的程式碼片段變成真的會編譯的檔案。

### 4.4 B 應該順手補上的兩個**文件缺口**（本次盤點發現）

兩者都是宿主一定會踩、而目前只存在於程式碼裡的事實：

1. **座標系手性**：核心用的是 OpenGL 式右手系——X 右、Y 上、**+Z 朝觀者**。證據是 `orthographic SideXY` 的 depth = −z（z 越大越近）與 raylib 3D 後端。Unity 是左手系（+Z 進畫面），所以 Unity 宿主必須翻 Z；不翻的話，`vortex` 場的旋轉方向會反過來（`cross` 用的是標準公式，手性是真的被固定住的）。目前**沒有任何文件寫過這件事**。
2. **`pbColor` 的位元組序**：實際是 `0xRRGGBBAA`（R 在高位、A 在低位，由 `Analytic.rampColor` 與 `Compile.clearAlpha = c .&. 0xFFFFFF00` 確證）。C header 的 `uint32_t* color` 一欄沒有說，宿主只能猜或反組譯。

第 2 點可以只在 header 加註解（純註解、不動任何宣告，仍在 add-only 規則內）。

### 4.5 C／D／E 的位置

- **C（多陣合成）** 是完整度維度 A 剩下那 15% 的全部——Init.md 對照表最後一列。放在 A 之後的理由是檔案衝突（兩者都改 `Compile`／`Interface`）與語意依賴（全域配額要用結構化預算表達）。真要提前，代價是 A 與 C 必須排序而非平行。
- **D（視覺）** 若限縮在 `app/*` 就與所有其他候選零交集，可以當第三條平行線；但一旦要加 `BillboardShape` 建構子就會撞到 `Compile`。建議先做純 `app/*` 的那半（3D 深度排序、俯視可讀性、相機操控）。
- **E（作者工具）** 是 POC 階段最容易延後、也最沒有損失的一項——現在的作者就是寫程式的人，熱重載＋錯誤上屏已經夠用。等到有非工程的作者時再做。

### 4.6 設計輪的兩個修正（2026-08-14，spec 0010–0014 設計時發現）

寫 spec 時逐檔盤點，§4.2／§4.3 的論證有兩處要修：

1. **4096 不只三份拷貝，還被測試釘成三方相等**：`test/FFIContractSpec.hs` 斷言 `PM_MAX_PARTICLES == pmMaxParticles == budgetCap == 4096`，而 `pmMaxParticles` 住在 `src/ffi/Magic/FFI.hs`——A 只要改 `budgetCap` 的**值**就必須同時改 B 的兩個主檔案，§4.3 的零交集即破。修正：**A（0010）本輪不改值**（結構化預算、SoA、量測照做；大規模吞吐以直接建構的 `CompiledSpell` 量），B（0011）交付 `pm_max_particles` 時把釘選改寫為「header 常數永釘 4096（第 1 代值）＋查詢鏡射律 `pm_max_particles ≡ budgetCap`」，**上限值的實際提升落在 C（0012）的 S1**——新值依 0010 的量測選定，届時 header 零觸碰。§4.2 的「乾淨解」仍然成立，只是分工從「B 鋪管道、A 改數字」修正為「B 鋪管道並鬆綁、C 改數字」。
2. **A 其實不必碰 `app/*`**（不改 cap 值 ⇒ `gpuCapacity` 不動），§4.3 表中 A 的殼層列作廢。於是 **D（0013，限縮 `app/*`）可以提前到第一波**，與 A、B 三方平行——複製 0007／0008／0009 三方零交集的成功結構。

另外兩處小修：`pm_depth_order` 需要新的 boundary 建構面（`Magic.Columns`，新檔案，見 0011 §0.3——boundary 凍結匯出刻意不開 `ParticleBuffer` 建構子，FFI 無法直接組 buffer）；E 的熱掃描與 D 撞 `app/Main.hs`／`Loop`／`Effects`，故 E（0014）動工門檻含 0013 驗收。

---

## 5. 建議的下一步（1.3 修訂：第一波 0010／0011／0013 全數驗收）

spec 0010–0014 對應候選 A／B／C／D／E，依 §4.6 的修正排為兩波：

- **第一波：三份全部驗收完畢（2026-08-15）** — ~~0010 = A（效能）~~ ✅ ‖ ~~0011 = B（宿主整合面）~~ ✅ ‖ ~~0013 = D（視覺，`app/*` 半場）~~ ✅。三方檔案零交集，各 spec §0.2 的逐檔證明事後全部成立，整合時只有 `SKILL.md`／`docs/*`／`.cabal` 的索引列需要人工併行。
- **第二波（門檻已全部解除，可立即動工）**：**0012 = C（多陣合成與場景層＋上限正式提升）** ‖ **0014 = E（作者工具）**。0012 的兩個前置（0010 的 `ParticleBudget`＋§9.2 選值建議 32 768–65 536、0011 的查詢鏡射律契約鬆綁）都已在手；0014 的前置（0010）與額外門檻（0013 驗收）亦已滿足。

理由一句話：A 把速度做出來（已完成，取樣快 3.4×、100k 粒 6.5 ms）、B 把管道鋪出去、D 把畫面看清楚——三件事互不碰檔案；然後 C 用 A 的量測與 B 的鬆綁把 4096 真正抬走，E 把作者回饋圈補完。

---

## 6. POC 與產品之間的分水嶺

以下三件事沒做完之前，這套系統適合「證明想法」，不適合「出貨」：

1. **效能**（候選 A）——**熱路徑已於 0010 交付**（100k 粒取樣 6.5 ms，速度面達標）；**護欄值仍是 4096**，把它抬到 10k–100k 是 0012 S1 的第一件事。
2. **多陣合成與全域配額**（候選 C）——真實遊戲裡不會只有一個法術在跑。
3. **視覺表現力**（候選 D）——**觀察面已於 0013 交付**（3D alpha 深度排序、軌道相機、2D 平移縮放、俯視深度色調），現在看得清楚了；但**表現面仍欠**：方形 quad 的表達力上限很低，而本專案的命題是「特效即魔法」，特效不好看命題本身就打折。下一輪視覺該動的是核心那半（`BillboardShape` 新建構子、`rbShape` 差異化），見 0013 §8-1。

反過來說，**架構本身不在這張清單上**。三環依賴、決定論、Circle as Data、維度無關、兩種消費模式——這些都已經是有測試守護的既成事實，後面每一輪都是在這個地基上加東西，而不是回頭改地基。這是目前這個專案最大的一筆資產。
