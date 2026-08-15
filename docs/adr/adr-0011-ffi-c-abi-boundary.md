---
id: adr-0011
type: adr
title: ffi-c-abi-boundary
status: accepted
created: 2026-08-14
updated: 2026-08-14
related-adr: [adr-0005, adr-0006, adr-0007, adr-0008]
related-spec: [func-0009]
---

# ADR-0011：C ABI FFI 邊界——foreign-library、JSON 進、SoA copy-out、handle 生命週期

- 狀態：已採納（2026-08-14）
- 相關：[architecture.md §5](../architecture.md)；ADR-0005（JSON 輸入介面）、ADR-0006（SoA 緩衝）、ADR-0007（核心零 IO）、ADR-0008（維度無關輸出）；落地 spec：0009

## 背景

專案目標是讓粒子魔法系統成為**可被其他遊戲專案納入的 library**。套件化回合（2026-08-13）已讓 Haskell 宿主能經 cabal 直接依賴 `particle-magic:magic-boundary`；但絕大多數遊戲宿主不是 Haskell——Unity（C#/P-Invoke）、Godot（GDExtension）、自製 C/C++ 引擎。使用者裁決（2026-08-14）：**庫必須可被 FFI 串接**，繪圖完全獨立於庫、由宿主（exe 或外部引擎）實作。

既有架構恰好已是「準 FFI 形狀」，這是本決策的成立基礎：

1. **輸入是 JSON**（ADR-0005）——跨邊界只需一個 `const char*`，`Circle` ADT 不需 marshalling。
2. **輸出是 SoA unboxed 六欄**（ADR-0006）——`pbPosX/Y/Z/Size/Life/Color` 天然對應六條連續記憶體的 `float*`/`uint32_t*`。
3. **生命週期 API 極小、無回呼、決定論**（ADR-0007、0005 凍結的 `castSpell`/`advanceSpell`/`observeSpell`/`isFinished`）——單向資料流，宿主不需要理解任何 Haskell 端狀態。

## 決策

**D1（消費模式與元件歸屬）** C ABI 是受支援的第二種消費模式（第一種：Haskell cabal 依賴）。以 cabal **`foreign-library`** stanza 交付（`type: native-shared`；Windows 加 `options: standalone` 內嵌 RTS），產出 `.dll`/`.so`。FFI 外殼是**外殼層元件**（與 exe 同位階）：`build-depends` 僅 `base` 與 `particle-magic:magic-boundary`，與 exe 相同的邊界紀律；`magic-core`/`magic-boundary` **零變更**。h-raylib 不參與。

**D2（輸入穿越）** 魔法陣以 **JSON 字串**穿越邊界（重用 `Magic.Codec.loadCircle`），施法脈絡以純量穿越（`float pos[3]`、`float facing[3]`、`uint64 seed`）。不提供 C 端的 `Circle` 建構 API——JSON 就是跨語言的建構語言（ADR-0005 的既定角色延伸）。

**D3（輸出穿越：copy-out 進宿主緩衝）** `pm_observe` 把粒子資料**複製**進宿主配置的六條 SoA 陣列，並填一個 batch 描述陣列（`offset/count/blend/shape` 區段）。這不只是「較安全」——`Data.Vector.Unboxed` 的底層 `ByteArray#` 可能未 pin、**沒有指標介面**，借出內部指標在結構上不可行；複製是唯一正解。成本：4096 粒 × 六欄 ≈ 98KB/幀的 `memcpy`，可忽略。宿主緩衝容量以 header 常數 `PM_MAX_PARTICLES = 4096` 定案（鏡射核心 `budgetCap`；重複常數的同步義務記入效能 spec 帳上，先例：0005 的 `gpuCapacity`）。

**D4（handle 生命週期）** `PmSpell*` = `StablePtr`（內含 `IORef ActiveSpell`）。`pm_cast` 配置、`pm_advance` 原地推進（純函數 `advanceSpell` 寫回 cell）、`pm_free` 釋放。**一 handle 一執行緒**（v1 無內部鎖）；double-free／use-after-free 為文件明定的未定義行為，與一般 C API 同慣例。

**D5（RTS 政策）** `pm_init`/`pm_shutdown` 以 C wrapper（`cbits/`）包 `hs_init`/`hs_exit`，冪等（重複呼叫安全）。foreign library 以 `-threaded` RTS 建置——宿主可從任意 OS 執行緒呼叫（每 handle 仍限單執行緒，見 D4）。

**D6（錯誤協定）** 回傳 handle 的函數失敗回 `NULL`，UTF-8 錯誤訊息寫入呼叫者提供的 `char* err_buf`（截斷安全）；數值函數回傳負數錯誤碼（`PM_OK = 0`、`PM_ERR_JSON`、`PM_ERR_BUDGET`、`PM_ERR_CAPACITY`…）。訊息文字重用 `renderLoadError`——與 demo HUD 上屏的是同一套人類可讀錯誤。

**D7（合約與版本）** `include/particle_magic.h` 是對外合約：交付後**只加不改**（同 JSON schema v1 紀律）；`pm_abi_version()` 供宿主啟動時核對。header 與 `foreign export` 清單的一致性由測試守護（行式剖析，BoundarySpec 手法）。

**D8（決定論跨越邊界）** 同 `(json, pos, facing, seed, dt 序列)` ⇒ 兩側逐位元同輸出：**FFI 路徑 ≡ Haskell 路徑**是可測等價律（in-process 直接呼叫 export 函數對照 `Magic.Interface`），不是文件承諾。

## 後果

**正面**：
- 「庫是完整的、繪圖在庫外」獲得最強形式的證明：非 Haskell 宿主拿六條陣列直接餵引擎頂點緩衝，庫零渲染假設（ADR-0008 的輸出無維度假設在此直接兌現）。
- FFI 層是純包裝——核心/邊界層零改動，與 0007（力場）、0008（2D 後端）檔案零交集，三 spec 可平行實作。
- 錯誤與決定論語意跨語言一致（D6/D8），宿主除錯體驗與 Haskell 端相同。

**負面**：
- `PM_MAX_PARTICLES` 是 `budgetCap` 的第三份重複常數（核心、`gpuCapacity`、header）——效能 spec 提高預算時三處同步，帳已記明。
- copy-out 每幀 ~98KB@4096；10k–100k 時約 0.24–2.4MB/幀，屆時由效能 spec 重新評估（可能改 pinned staging 或 Storable 化）。
- Windows `standalone` 模式把 RTS 打進 DLL，產物體積較大；一行程限載入一份（GHC RTS 限制），多 DLL 消費者需注意。
- 熱重載不提供 FFI API——宿主自行重新 `pm_cast`（語意上等同 demo 的重載＝重施法，ADR-0005/0010 D8 一致）。

## 被否決的替代方案

- **C struct marshalling `Circle`**：槽位×符文×Expr 的型別面積在 C 端爆炸，且與 JSON schema 形成兩套要同步的合約；JSON 已是為此而生的穿越格式（ADR-0005）。
- **零拷貝借出內部指標**：unboxed 向量無指標介面，結構上不可行；若改存 pinned/Storable staging，等於在 FFI 層養一份隱藏狀態換 98KB 的 memcpy——不值。留給效能 spec 在真實量級下重評。
- **兩段式容量查詢（先問 count 再填）**：每幀取樣兩次（`observeSpell` ≈0.66ms@4096 直接翻倍）；header 常數＋`PM_ERR_CAPACITY` 防呆更便宜。
- **回呼式串流輸出**：跨 FFI 回呼進 Haskell 的複雜度與重入風險，換不到任何資料量優勢。
- **C++ API／各語言 binding 直接交付**：C ABI 是所有語言 FFI 的最大公約數；C#/GDScript 包裝是宿主側一頁紙的事，不屬於庫的責任面。
