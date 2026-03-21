#pragma once
// padctl WASM plugin SDK — C header
// Compile your plugin to WASM targeting "env" import module.
// All pointer arguments are offsets into the plugin's linear memory.

#include <stdint.h>

// --- host imports (declare as extern, provided by padctl) ---

// Read a Feature Report. Returns byte count read, <0 on error.
extern int32_t device_read(int32_t report_id, uint8_t *buf, int32_t buf_len);

// Write an Output Report. Returns bytes written, <0 on error.
extern int32_t device_write(const uint8_t *buf, int32_t buf_len);

// Write a log message. level: 0=debug, 1=error.
extern void log(int32_t level, const char *msg, int32_t msg_len);

// Read a device config field value as a UTF-8 string. Returns byte count.
extern int32_t get_config(const char *key, int32_t key_len, char *val, int32_t val_cap);

// Write a cross-frame persistent key-value entry.
extern void set_state(const char *key, int32_t key_len, const char *val, int32_t val_len);

// Terminate the plugin with an error message (triggers wasm3 trap).
extern void abort(const char *msg, int32_t msg_len);

// --- plugin exports (implement these in your plugin) ---

// Called once after device init commands complete.
// Return 0 on success, negative on error. Timeout: 5s.
int32_t init_device(void);

// Called with calibration Feature Report bytes.
// Return 0 on success. No hard timeout (low frequency).
int32_t process_calibration(uint32_t cal_buf_ptr, uint32_t cal_buf_len);

// Called per input report when wasm.overrides.process_report = true.
// Write override field values into out buffer.
// Return number of bytes written; 0 = no override. Timeout: 1ms.
int32_t process_report(uint32_t raw_ptr, uint32_t raw_len,
                       uint32_t out_ptr, uint32_t out_len);
