---
id: ADR-025
type: adr
title: host-runtime-subsystem-split
description: 從 boundary-host 切出 host-runtime 子系統接管嵌入執行期
status: accepted
created: 2026-08-20
updated: 2026-08-20
---

# ADR-025: 子系統重劃——從 boundary-host 切出 host-runtime

## 狀態（Status）

accepted（2026-08-20）。修訂 `.design/system.md` 的子系統劃分與 `legacy-map.md` 的主場歸屬（三份舊規格換主場）。不改任何程式碼的套件歸屬——cabal target 本來就是分開的。

## 背景（Context）

現行 boundary-host 是「系統對外的唯一合約面」，一份 Level 2 設計管八個模組：編解碼、法術入口、場景層、投影、空間摘要、欄位回灌、**C ABI 外殼**、**參考綁定與範例**。production 審計找到的缺口（[ADR-022](ADR-022-host-runtime-contract.md) 背景的七項、[ADR-023](ADR-023-host-buffer-contract.md) 的宿主緩衝、封裝與發布產物、Unity 的 native array 路徑、out-of-process 測試）**全部落在後兩個模組加 `cbits/`**。若照現狀把這些項目塞進 boundary-host 的路線圖，它的模組數會從八長到十四、契約卡會從六張長到十八張，而其中一半的卡片談的是 RTS、執行緒、記憶體所有權、平台封裝——與另一半（JSON 編解碼、場景配額、投影）幾乎沒有共同詞彙。

切分依據照 `system.md` 自己定的規則：**cabal 的實際依賴邊界與模組歸屬**。`particle-magic-ffi` 是獨立的 foreign-library target，只依賴 `magic-boundary`，加上 `cbits/`、`include/`、`bindings/` 三個不屬於任何 Haskell 套件的資料夾——它在建置圖上早就是一個獨立節點，只是設計文檔沒有跟上。

## 決策（Decision）

### D1（新子系統 host-runtime）

新增子系統 `host-runtime`（嵌入執行期），職責：**把邊界層的 Haskell 契約變成宿主進程裡一個安全、可調、可診斷的共享函式庫**。涵蓋：

- C ABI 外殼（`src/ffi/`）、RTS 生命週期與設定（`cbits/`）、`include/particle_magic.h`
- 例外防火牆、控制代碼註冊、執行緒模型（ADR-022）
- 宿主緩衝觀測的 C 面與整塊複製（ADR-023）
- 診斷統計（ADR-022 D6）
- 各語言綁定（`bindings/`）與非 Haskell 宿主範例（`examples/c/`、`examples/unity/`）
- 共享函式庫的封裝：standalone 連結、MSVC 匯入庫、發布產物的**內容**（產物的 CI 流程仍屬 authoring-engineering）
- `docs/integration.md` 的 C／C++／Unity 章節

**明確不做**：不含任何魔法語意；不重新定義邊界層的 Haskell 契約（它消費那份契約，不改它）；不選繪圖 API；不做 Haskell 宿主的接入（那是 boundary-host 的 Haskell 面）。

### D2（boundary-host 瘦身為 Haskell 面契約）

boundary-host 保留：編解碼、法術生命週期入口、場景層、投影、空間摘要、欄位回灌，以及 Haskell 宿主範例（`examples/haskell/`）與 `docs/integration.md` 的 Haskell 章節。它仍是「唯一依賴點」——host-runtime、render-shell、authoring-engineering 都只依賴它。**C ABI 的 31 個凍結符號不因搬家而改變任何一個位元**；凍結的權威仍是 header 本身。

### D3（依賴方向）

```text
render-shell ──┐
authoring-eng ─┼─→ boundary-host ─→ { magic-semantics, expr-language, particle-simulation }
host-runtime ──┘
```

host-runtime 只依賴 boundary-host，由 cabal 結構強制（foreign-library 的 build-depends 不含 `magic-core`），`test/BoundarySpec.hs` 既有的守護直接涵蓋。

### D4（舊規格換主場）

`legacy-map.md` 中三份舊規格的主場自 boundary-host 改為 host-runtime：

| 舊 id | feature | 理由 |
|---|---|---|
| func-0009 | ffi-foreign-library | C ABI 骨架、RTS wrapper、`.def` 匯出清單 |
| func-0011 | host-integration-surface | 綁定、C／Unity 範例、整合指南 |
| func-0018 | scene-c-abi | 場景層的 C 面 |

func-0001（骨架）、func-0008（投影）、func-0012（場景層）、func-0025（空間摘要）、enhance-0001（Haskell 宿主接入）留在 boundary-host。「一份規格恰屬一個子系統」的規則不變，只是三份換了歸屬。

### D5（測試歸屬）

既有的 `test/FFI*Spec.hs`、`test/BindingContractSpec.hs`、`test/ExampleHostSpec.hs` 中的 C／Unity 部分歸 host-runtime；新增的 out-of-process 載入測試（ADR-022）是 host-runtime 專屬的測試型態——它是整個專案唯一需要真的載入產出物的測試。

## 考慮過的替代方案（Alternatives Considered）

- **不切，全部塞進 boundary-host**：十四個模組、十八張契約卡，且 `/subsys-build` 委派時一份 design.md 要同時回答「JSON 往返律」與「nursery 大小」。契約卡品質會垮，這是切分的直接動機。
- **切成兩個新子系統（C ABI 與 bindings/packaging 分開）**：bindings 與 packaging 沒有獨立的契約面——它們的契約就是 header；分開只會多一份幾乎空的 design.md。
- **把執行期的事放進 authoring-engineering（它管 CI 與發布）**：authoring-engineering 的鐵律是「產物一行都不進出貨的庫」，而 RTS 設定與防火牆正是出貨的庫的一部分。放錯家會讓那條鐵律失效。
- **改 cabal 結構把 ffi 併進 magic-boundary**：方向相反——會讓 Haskell 宿主被迫連結 RTS wrapper 與 C 檔；現有的分離是對的，文檔該跟上它。

## 影響（Consequences）

- `.design/system.md`：`subsystems` 清單加入 `host-runtime`；子系統劃分新增一節、boundary-host 一節改寫；拓撲與架構圖更新。
- `.design/subsystems/host-runtime/design.md` 新建（`/subsys-design`），已交付的三份舊規格列為其 feature 歷史，ADR-022／023 的條款展開為路線圖與契約卡。
- `.design/subsystems/boundary-host/design.md`：移除 M7、M8 與對應契約卡；路線圖的 `cast-many-c-abi`、`ffi-thread-safety` 移交 host-runtime（前者是 C 面、後者被 ADR-022 D4 吸收）；`more-language-bindings` 同樣移交。
- `legacy-map.md`：D4 的三列換表。
- 程式碼零變更；`cabal` 檔零變更。
