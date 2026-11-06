// Offline tests only (unit-engine): the engine as globalThis.sofaEngine, injected by a BiDi preload
// script that hands it a channel. Sofa itself never drives Firefox over BiDi - YouTube refuses a
// browser under remote control (docs/youtube-engine.md); it uses the extension (page-main.ts).
import { sofaEngine } from './engine.ts';
import type { SofaEngine } from './engine.ts';

(globalThis as typeof globalThis & { sofaEngine?: SofaEngine }).sofaEngine = sofaEngine;
