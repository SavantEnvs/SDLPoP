// Disable LeakSanitizer at build time (SPEC §6.2 item 15). `prince validate` ends with exit(0)
// while the game still holds its SDL surfaces and resource buffers, so every run would otherwise
// "leak". ASan and UBSan stay fully active.
int __lsan_is_turned_off(void) { return 1; }
