---
id: enhance-0001
type: enhance
title: haskell-2d-host-onboarding
description: 補上 Haskell 宿主範例與 2D 像素風接法食譜
status: done
created: 2026-08-16
updated: 2026-08-16
related-adr: [adr-0008]
related-spec: [func-0008, func-0011, func-0013]
---

# 改善提案：Haskell 2D／像素風宿主的上手路徑

> 狀態：**已落地**（2026-08-16。裁決見 §5，Todo 與測試對照見 §6，偏離與發現見 §8。本輪執行 E1＋E2；E3 取案 B，程式碼未搬家）
> 驗證：`cabal test` **1273 examples／0 failures**（本輪新增 13）；`examples/haskell` 的 `cabal build` 綠，`cabal run -v0 pm-haskell-host | diff - expected-output.txt` 無差異
> 性質：改善提案 —— 主體是**文件與範例**，不新增功能、不改既有語意。唯一觸及程式碼的是 E3，而 E3 是**搬家**而非新寫，且它是否該做需要開發者拍板（見 §2.3）。
> 相關文件：[integration.md](../integration.md)（本提案的主要修改對象）、[roadmap.md](../roadmap.md) §4.4（「文件缺口」的既有記帳位置）、[ADR-0008](../adr/adr-0008-dimension-agnostic-3d-first.md)（維度無關核心、投影屬外殼）、[func-0008](../spec/func-0008-ortho2d-backend.md)（2D 正交後端）、[func-0011](../spec/func-0011-host-integration-surface.md)（宿主整合面）、[func-0013](../spec/func-0013-visual-expressiveness.md)（`fvDepthTint`、flat camera）
> 起因：開發者提問「其他 Haskell 專案要怎麼引入這套系統？我手上是 2D pixel art 素材的遊戲，套得上嗎？」——查核後**兩個問題的答案都是肯定的，但兩者都缺一段路**。

---

## 1. 現況

### 1.1 「怎麼引入」其實有文件，但不容易被發現，也沒有可跑的證據

`docs/integration.md` **§3 路線 A：Haskell 宿主**已經寫得相當完整：`source-repository-package` 的接法、`build-depends: particle-magic:magic-boundary`、只 import 哪四個模組、`runSpell` 骨架、§3.1 的預算與 AABB 查詢、§3.2 的合成與 `Scene` 場景層。`particle-magic.cabal` 也已經把 `magic-core`／`magic-boundary` 都標成 `visibility: public`。

換句話說**「打包成其他 Haskell 專案可直接引入的方案」這件事在技術上已經成立了**，不需要額外的打包工作。缺的是三樣：

| 缺口 | 證據 |
|---|---|
| **沒有可編譯、可跑的 Haskell 宿主範例** | `examples/` 底下只有 `c/main.c` 與 `unity/`（`PmSmoke.cs`、`SpellRenderer.cs`）。`examples/haskell/` 不存在。Haskell 路線只有 integration.md 裡的片段，而那些片段沒有任何測試或建置在守護 |
| **非對稱**：兩條非母語路線有真檔案，母語路線沒有 | roadmap §4.2 明文說 `examples/c/main.c` 是「庫必須完整、繪圖在庫外」這條原則的**可執行證明**；同一個標準下，Haskell 路線目前是唯一沒有可執行證明的一條 |
| **發布流程** | 未上 Hackage，只有 git tag。這一項**已有主人**：`func-0019`（status: open）負責 CI、版本語意、tag 格式與 Linux 實測。本提案不重複記帳，只在此註明「引入路徑」的最後一段在那裡 |

### 1.2 2D／像素風套得上，但有四件事文件沒講

庫這一側該給的都給了：`Magic.Projection`（= `Magic.Project` 的 boundary 再匯出）提供 `orthographic plane p → (V2, depth)` 與 `depthOrder plane buffer → 由遠而近的索引置換`，`rbShape` 只是一個 enum tag（宿主自行決定綁什麼貼圖），16384 的上限對像素風遊戲是天文級的過剩。

但一個實際要動手的 2D 宿主會立刻撞到四件 integration.md **目前沒有寫**的事：

1. **`casterFacing` 的方向是個設計決定，不是預設值問題。**
   `Magic/Compile.hs:287-293` 定義：局部 +Z ＝ `casterFacing`，`Anchor` 的骨架法線 ＝ +Z ＝ facing。也就是**初始面垂直於 facing，立體擴充沿 facing 前進**。於是：
   - **側視卷軸**（`SideXY`，丟 Z）：facing 必須躺在 XY 平面內。demo 用的正是 `casterFacing = V3 0 1 0`（`app/Main.hs:54`），擴充往畫面上方跑 —— 「地上一個陣、光柱往上射」，看起來對。
   - **俯視 Zelda 式**（`TopXZ`，丟 Y）：如果 facing 還是 `V3 0 1 0`，**擴充方向恰好是被丟掉的那一軸**，整根柱子塌成它自己的足跡。你會看到陣，但看不到它在動。正確做法是讓 facing 躺在 XZ 平面內（例如角色面向 `V3 0 0 1`），陣就會立在地面上、往角色前方延伸。

   這是本提案認為最該補的一條：它不會報錯、不會崩潰，只會讓畫面看起來「怪但說不出哪裡怪」。同一類的先例是 §4.4 的手性問題（手性錯了只有 `vortex` 轉反）——那一條在 0011 補進 header 之後就不再咬人了。

2. **世界單位 ↔ 像素的映射沒有食譜。** `size` 是世界單位的半邊長（邊長 = `2 × size`），要落到像素得自己選一個 pixels-per-unit。最省事的慣例是「1 世界單位 = 1 tile，PPU = tile 的像素數」，這樣魔法陣 JSON 裡的半徑就直接是 tile 數。這段邏輯**專案內已經寫好而且測過了**，見 §2.3。

3. **像素對齊。** 位置是 `Float`。逐顆 `round` 到像素格會讓慢速粒子抖動；標準解法是把場景畫到原生解析度的 render target 再整數倍放大，粒子與美術素材自然落在同一格上，且完全不必碰粒子座標。

4. **顏色會跟 limited palette 打架。** `color` 是沿 color ramp 依 `life` 內插出來的連續漸層（`0xRRGGBBAA`，integration.md §2.1）。像素風通常是受限調色盤。兩條路：後處理做 palette 量化（查最近色），或把 ramp 端點設計成剛好命中調色盤。這是美術方向的決定，庫不該插手，但**文件該告訴人這個張力存在**。

---

## 2. 提案

三項，按「不需要決策 → 需要決策」排序。E1／E2 可獨立落地，E3 需開發者裁決。

### 2.1 E1 — `examples/haskell/`：一個最小、可編譯、不畫圖的 Haskell 宿主

**做法**：比照 `examples/c/main.c` 的定位 —— 一個**不畫任何東西**的宿主，載入一張範例陣、施法、跑固定時步若干幀、把每幀的批次摘要與前幾顆粒子印出來。它證明的是**整合路徑**，不是渲染。

**兩個要決定的細節**：

- **是否用獨立的 `.cabal`**：放成根專案的一個 executable stanza 最容易建置（`cabal build all` 直接涵蓋），但那樣**證明不了外部消費** —— 它用的是同一個 package，`source-repository-package` 那條路徑一個字都沒被走過。放成 `examples/haskell/` 底下自帶 `.cabal` 與 `cabal.project`（以相對路徑指回 `../..`）才真的走過那條路，代價是它落在根 `cabal build all` 之外，要另一行指令。
  **建議取後者**，理由與 `examples/c/main.c` 需要另外 `gcc` 一次相同：範例的價值在於它跟真實使用者走同一條路。CI 上的那一行由 `func-0019` 順手收（本提案不替它決定）。
- **不引入 renderer 依賴**：h-raylib 在 CI 上是最貴的一項（func-0019 §0.1 已記為頭號成本），範例沒有理由把它拖進來。想看畫面的人有 demo exe。

**驗證方式**：範例的逐幀輸出應與 demo／C 宿主同一組輸入下逐行一致（決定論由 ADR-0011 D8 保證）。若 E1 要進 CI，這個一致性就是它的斷言。

### 2.2 E2 — integration.md 新增一節：「2D／像素風宿主食譜」

位置建議在 §3 之後（或 §3.3），內容就是 §1.2 的四條，寫成可照做的步驟：

1. **選視角與 facing**：一張「遊戲類型 → `ViewPlane` → `casterFacing` 該指哪」的對照表（側視卷軸 / 俯視 / 斜俯視 3/4），連同「選錯只會怪、不會壞」的症狀說明。
2. **選 PPU**：「1 世界單位 = 1 tile」慣例 + 邊長 `2 × size × PPU` 的算式。
3. **像素對齊**：低解析 render target + 整數倍放大；說明為何不建議逐顆 round。
4. **調色盤**：連續 ramp 與 limited palette 的張力，兩條解法。
5. **貼圖**：`rbShape` 是 tag 不是資產 —— demo 的 64×64 程序化貼圖（`app/App/Render/Sprite.hs`）是 demo 的選擇，宿主換成自己的 8×8 像素圖完全合法。
6. 順手把 §8「目前的限制」補一列：**沒有 2D 宿主的參考實作**（E1 落地後即可刪掉這一列）。

**同時建議**：在 roadmap §4.4「本次盤點發現的文件缺口」加上 §1.2 這四條，讓它跟手性那一條並列 —— 那一節的存在就是為了收這種「不寫也不會壞、寫了才不咬人」的洞。

### 2.3 E3 — 螢幕映射三函數的歸屬（**需要開發者裁決**）

**現況**：`app/App/Render/Flat.hs` 裡的 `screenOf`／`panBy`／`zoomAt`／`resizeTo`（＋ `minPixelsPerUnit`／`maxPixelsPerUnit`）是**純函數、renderer-agnostic、有 property 測試**（`test/FlatCameraSpec.hs`：pan 的線性律、zoom 的定點律、idle 逐位元恆等）。它們正是 §1.2-2 那個缺口的答案。

但它們住在 demo executable 的 `other-modules` 裡，外部宿主**依賴不到**。於是每個 2D 宿主都得重寫這 ~50 行，而重寫的風險不是難，是「寫出來的 zoom 沒有定點性質」——跟 0011 把 `pm_project`／`pm_depth_order` 送上 C ABI 的理由一模一樣（integration.md §4.5：「重寫的風險不是難，是排出來跟 Haskell 路徑不一樣」）。

**兩案**：

| | 案 A：提升到 `magic-boundary` | 案 B：只在文件裡指路 |
|---|---|---|
| 做法 | 新增 boundary 模組（暫名 `Magic.Screen`），內含 `ScreenView` 記錄 + 四個函數 + 兩個常數；`App.Effects.FlatView` 改為它的別名或直接被取代，`App.Render.Flat` 只留 `buildFlatQuads` | E2 裡加一段「這段邏輯的參考實作在 `app/App/Render/Flat.hs`，歡迎照抄，注意保住 zoom 的定點律」 |
| 依賴影響 | **零**：純 `base` 算術，不動 `magic-boundary` 的 build-depends 白名單（`test/BoundarySpec.hs` 守護的那份） | 零 |
| 代價 | 這是**新增一個對外凍結介面** → 依 SKILL.md 需要一份 ADR，且 `FlatView` 目前出現在 `App.Effects` 的 `DrawFlat` 效果簽章上，搬家會牽動 `App.Effects`／`App.Loop`／`App.Hud`／`App.TestInterp`／`App.Render.Raylib3D` 與數個測試模組的 import。是機械改動，但不是零改動 | 每個宿主重寫一次，且性質律沒有東西在守護 |
| 界線疑慮 | `fvOrigin`／`fvPixelsPerUnit` 被 func-0008 明文標為「**shell 端的呈現選擇，不凍結**」（`App/Effects.hs` 的註解）。把它提升成凍結介面，是對那個判斷的**翻案** —— 這是本案真正的爭點，不是工作量 | 保持 ADR-0008「投影屬外殼」的字面立場 |

**注意 `buildFlatQuads` 不在候選內**：它輸出 `QuadBatch`（`Data.Vector.Storable`，為 raylib 的 dynamic mesh 而生），那是貨真價實的 shell 專屬品，不該進 boundary。

**本提案的傾向**：先做 E1／E2（案 B 的敘述），把 E3 留成 E1 實作過程中的一個實測問題 —— 如果寫 `examples/haskell/` 時發現「不照抄 Flat.hs 就寫不出來」，那就是案 A 的證據；如果範例根本不需要 pan/zoom（不畫圖的宿主確實不需要），那案 A 就還沒到需要決定的時候。**先讓需求出現，再凍結介面**，與 ADR-0012 D8 延後 `pm_scene_*` 的理由同構。

---

## 3. 預期效益

- **母語路線補上可執行證明**：三種消費模式（Haskell 子庫／C ABI／C# 綁定）在「有真檔案可跑」這件事上對齊，`examples/` 不再獨缺最該有的那一條。
- **2D 宿主少踩一個沉默陷阱**：`casterFacing` 與視角平面選錯不會報錯，只會讓畫面看起來平白無味。這一條寫下來的價值，等同 0011 把手性寫進 header。
- **像素風專案的可行性從「應該可以」變成「照這五步做」**：ADR-0008 宣稱的「本質不變、只換投影」第一次被一個非 raylib、非 3D、非連續色彩的實際場景檢驗。
- **E3 若成案，zoom 的定點律與 pan 的線性律成為所有 2D 宿主共享的保證**，而不是每個宿主各自賭一次。

---

## 4. 非目標

- **不寫 gloss backend。** 已評估並否決：gloss 的 blend function 在初始化時寫死成 `SrcAlpha`/`OneMinusSrcAlpha`，`BlendAdditive`（`Magic/Compile.hs:112`）無法表達 —— 那是魔法發光的本體；且它是 immediate-mode，每幀要組 boxed `[Picture]`，ADR-0006 的 SoA 與 ADR-0009 的單一 dynamic mesh 全部失效。top-down 3/4 視角用既有的 orbit camera（`App.Camera`，elevation ~35-45°）即可，見下條。
- **不做 3/4 視角的正交投影模式。** 若日後要讓斜俯視成為**正式支援的輸出平面**（`ViewPlane` 加一個帶俯角的建構子，`depthOrder` 因已參數化而自動跟上），那是一份獨立的 spec，不是本提案的範圍。本提案只在 E2 的視角對照表裡註明「3/4 目前的做法是 3D 相機拉俯角」。
- **不碰發布流程**（Hackage、版本語意、CI）——`func-0019` 的地盤。
- **不改任何既有語意、不動 JSON schema、不加 rune、不升 ABI 版本。**

---

## 5. 開發者裁決（2026-08-16）

三項全數採納本提案的建議：

1. **E1 的範例形態 → 獨立 `.cabal`。** `examples/haskell/` 自帶 `.cabal` 與 `cabal.project`（以相對路徑指回 `../..`），真的走過一次外部消費路徑；代價是它落在根 `cabal build all` 之外，要另一行指令，與 `examples/c/main.c` 需要另外 `gcc` 一次同款。
2. **E3 → 案 B，暫不做。** 螢幕映射三函數留在 `app/App/Render/Flat.hs`，E2 裡指路並說明「照抄時要保住 zoom 的定點律」。保持 ADR-0008「投影屬外殼」的字面立場；等 E1 或真實宿主證明「不照抄就寫不出來」再開 ADR。
3. **落地方式 → 直接作為本 enhance 的實作輪次**（不另開 func-spec），依 SKILL.md 由 `spec-impl` 消化。

---

## 6. 本輪 TodoList 與 1-to-1 測試對照

全部測試集中在新檔 `test/ExampleHostSpec.hs`，比照 `test/BindingContractSpec.hs` 的定位：範例不由本專案的 `cabal build all` 編譯，所以沒有文字契約測試守著，它就會在無人察覺的情況下腐爛。

- [x] **S1** 獨立 package 骨架
- [x] **S2** `Main.hs` 最小宿主
- [x] **S3** golden 逐幀輸出
- [x] **S4** 跨宿主等價
- [x] **S5** `extra-source-files` 收錄
- [x] **S6** integration.md 的 2D／像素風食譜

| # | Todo | 對應測試（`ExampleHostSpec.hs`） |
|---|---|---|
| **S1** | `examples/haskell/` 獨立 package：`particle-magic-example.cabal`＋`cabal.project`（相對路徑指回 `../..`） | 「範例是外部消費者：依賴 `magic-boundary`、碰不到 `magic-core`、不連 renderer」＋「`cabal.project` 指回倉庫根」 |
| **S2** | `Main.hs`：不畫圖的最小宿主——載入陣、施法、120 幀固定時步、逐幀摘要 | 「範例只 import integration.md §3 列出的 boundary 模組」（白名單雙向：多 import 一個核心模組就紅） |
| **S3** | 逐幀輸出落成 golden（`examples/haskell/expected-output.txt`），供人工 `diff` | 「in-process 參考路徑（`Magic.Interface`，與範例同一組常數）逐行等於 golden」 |
| **S4** | 跨宿主等價：同一組輸入下 C ABI 路徑與 Haskell 路徑的每幀數值相同 | 「以 `Magic.FFI` in-process 比照 `examples/c/main.c` 的呼叫序驅動，121 行逐行等於 golden」 |
| **S5** | `particle-magic.cabal` 的 `extra-source-files` 收錄範例四檔 | 「範例的每一個檔案都在 `extra-source-files` 裡」（缺一即紅） |
| **S6** | integration.md 新增 §3.3「2D／像素風宿主食譜」六條＋§8 補限制列＋§1／§3 指向新範例 | 「食譜節存在，且視角對照表同時出現 `SideXY`／`TopXZ`／`casterFacing`」＋「§3 的模組清單數字與實際列出的模組數一致」＋「文中指向 `examples/haskell/`」 |

收尾的文檔記帳（roadmap、本檔 `status`、integration.md 版本號）見 §7，不另立 Todo。

---

## 7. 落地後的收尾動作

- [x] 本檔 `status` → `done`，`updated` 同步。
- [x] integration.md 版本號與日期上調（1.2 → **1.3**）。
- [x] roadmap 的文件缺口記帳：**§3.3 新增五列**（兩列 `~~刪除線~~ ✅`、三列刻意不做的記帳），版本號 2.0 → **2.1**；§4.4 補一段體例續用的註記（改記位置的理由見 §8.1-3）。
- [x] `particle-magic.cabal` 的 `extra-source-files` 加入該範例的五個檔案，與 `examples/c/main.c`、`bindings/csharp/ParticleMagic.cs` 並列（`ExampleHostSpec` 逐檔守護，日後新增一個檔案而忘了登記就會紅）。

---

## 8. 實作備註（偏離與實作中的發現）

### 8.1 對提案原文的三處偏離

1. **§2.2 第 6 條的「補一列再刪掉」改判為「收窄後留下」。** 原文說 §8 先補「沒有 2D 宿主的參考實作」，E1 落地後即可刪。但 E1 是**不畫圖**的宿主，它證明的是整合路徑而不是渲染，所以那一列並沒有被 E1 結清。實際寫進 integration.md §8 的是收窄後的版本：**「像素風只有食譜，沒有像素風的參考實作」**，並點名 demo 的 flat view（`App.Render.Flat`）是 2D 但**連續色彩＋64×64 程序貼圖**，食譜第 3、4 條（低解析 render target 整數倍放大、調色盤量化）沒有任何範例走過。誠實清單裡留一列真的，比刪掉一列假的好。
2. **食譜節首明寫「不分語言」。** 位置照提案放在 §3.3，但那會讓它看起來像 Haskell 專屬——實際上除了第 1 步的程式碼片段，每一條對 C／C# 宿主一字不差適用。因此節首加了這句，並從 §1 的路線表與 §4.5 交叉指路。
3. **roadmap 的記帳位置從 §4.4 改到 §3.3。** 提案原文說「在 roadmap §4.4 的文件缺口清單加上這四條」，但 §4.4 是 0011 規劃回合的**歷史小節**，而 §3.3「介面／宿主」才是活的欠款總表——當年那兩條缺口也是鏡射到 §3.3 才被劃掉的。四條缺口與兩條「刻意不做」因此記在 §3.3，§4.4 只補一段體例續用的註記。

### 8.2 實作中才浮現的兩條事實（都已回寫文件）

1. **Haskell 宿主的依賴面是四個，不是兩個。** integration.md §3 原本只寫 `build-depends: particle-magic:magic-boundary`，照抄**編不過**：`Magic.Codec.loadCircle` 吃的是原始位元組（要 `bytestring`），而 `ParticleBuffer` 的六條欄是 `Data.Vector.Unboxed`（ADR-0006，要 `vector`）。這是「只有文件片段、沒有東西編譯它」最典型的代價——寫 E1 的第一分鐘就撞到了。已補進 §3 與範例的 `.cabal` 註解。
2. **`dt` 的寬度是跨宿主等價的前提。** `pm_advance` 收的是 `float`，進來之後才加寬成 double。所以一個在自己原始碼裡寫 `1.0f/60.0f` 的 C 宿主，和一個寫 `1/60 :: Double` 的 Haskell 宿主，**跑的不是同一個模擬**——決定論是 per-input（ADR-0011 D8），而 `dt` 是輸入之一。範例刻意收窄成 `float2Double (1/60 :: Float)` 以換取與 `examples/c/main.c` 的可 diff 性，並在 README、原始碼註解與 `ExampleHostSpec` 檔頭各寫了一次。（`test/FFIHarness.hs` 的 `step` 一直就是這樣做的，所以 S4 的兩條路徑不必額外對齊就對上了。）

### 8.3 E3 的後續判準

實作 E1 的過程中**沒有**出現「不照抄 `Flat.hs` 就寫不出來」的情況——不畫圖的宿主確實不需要 pan／zoom，如 §2.3 所預測。所以案 A 的觸發條件仍未滿足，記帳留在 roadmap §3.3。下一個會觸發它的事件是**真的有人要畫一個 2D 宿主**（食譜第 3 條的低解析 render target 一旦要做，`screenOf` 就免不了）。

### 8.4 未觸及

- **CI**：`examples/haskell/` 落在根 `cabal build all` 之外，要另一行指令；把那一行收進 CI 是 **func-0019** 的地盤，本輪未動 `.github/workflows/ci.yml`。
- **CHANGELOG.md**：格式規則是「一份 func-spec 一則」（`docs/release.md` §3），本輪不是 func-spec，版本號亦未動，故未加條目。
