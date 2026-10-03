# llm.vhdl

Full-fabric VHDL LLM inference engine. Runs Qwen3.5-class transformer
inference (9B on a single card, 27B targeted across two) entirely in FPGA
fabric. See `docs/` for the architecture, the subsystem breakdown, and the
hardware bring-up notes.

## License

MIT (see [LICENSE](LICENSE)). Third-party components and their licenses are
listed in [NOTICE](NOTICE); the web UI in `ui/` is derived from the llama.cpp
web UI (MIT) and keeps its upstream notice in `ui/LICENSE.llama.cpp`.
