---
id: adr-0004
type: adr
title: no-ecs-dataflow
description: 架構採資料流而非 ECS，粒子是被算出來的輸出
status: accepted
created: 2026-08-11
updated: 2026-08-16
related-adr: []
related-spec: []
---

# ADR-0004：不採用 ECS，採資料流架構

- 狀態：已採納（2026-08-11，由 Init.md 直接指定）
- 相關：[architecture.md §2, §3](../architecture.md)

## 背景

遊戲界主流架構是 ECS（Entity-Component-System），Haskell 也有 apecs 等實作。Init.md 明確指定不用 ECS。本 ADR 記錄這個約束的理由與架構後果，使其成為可追溯的決策而非隱性前提。

## 決策

採**資料流（dataflow）架構**：系統是一條純函數管線

```
JSON → Circle → CompiledSpell → (每幀) Time → ParticleBuffer → RenderBatch
```

沒有實體、沒有元件註冊表、沒有系統排程器。狀態被壓縮到兩處：宿主持有的 `ActiveSpell`（含可選 `FieldState`）與外殼的 IO 邊界。

## 後果

**正面**：
- 與純函數核心的目標天然一致：ECS 的核心價值（異質實體的動態組合與可變狀態管理）正是本系統刻意不要的東西——魔法是編譯自資料的確定性函數，不是一群可變實體。
- 資料流管線的每一段可獨立測試、獨立替換；依賴方向單一。
- 沒有 ECS 框架的學習與整合成本，也沒有排程器帶來的執行順序隱性耦合。

**負面**：
- 未來若系統嵌入的宿主遊戲本身用 ECS，邊界處需要一層轉接（宿主實體 → `CastContext`；`RenderBatch` → 宿主渲染元件）。`Magic.Interface` 的設計已把這層轉接的面積壓到最小。
- 「魔法影響遊戲世界」（傷害、擊退等 gameplay 效果）不在本系統內建模，需由宿主查詢粒子/發射器狀態自行結算——這是刻意的關注點分離，但也表示本系統單獨不構成完整玩法。

## 被否決的替代方案

- **apecs（Haskell ECS）**：成熟、效能好，但把魔法建模成實體+元件會引入全域可變 World，核心純度目標直接失守；且本系統的「實體」（粒子）是同質海量資料，SoA 緩衝比 ECS 的元件儲存更貼合。
- **FRP（reactive-banana / Yampa）**：與純函數目標相容，訊號函數也很優雅，但對「海量粒子每幀重取樣」的場景是錯誤的抽象層級（FRP 管的是少量訊號的時間語意，不是十萬粒子的資料平行），且除錯與效能特性難以預測。
