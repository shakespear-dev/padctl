(module
  (import "env" "log" (func $log (param i32 i32 i32)))
  (import "env" "set_state" (func $set_state (param i32 i32 i32 i32)))
  (import "env" "get_state" (func $get_state (param i32 i32 i32 i32) (result i32)))
  (import "env" "device_read" (func $device_read (param i32 i32 i32) (result i32)))
  (import "env" "device_write" (func $device_write (param i32 i32) (result i32)))
  (import "env" "get_config" (func $get_config (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (export "init_device" (func $init))
  (export "process_calibration" (func $calib))
  (export "process_report" (func $report))
  (func $init (result i32) i32.const 0)
  (func $calib (param i32 i32))
  (func $report (param i32 i32 i32 i32) (result i32)
    local.get 2
    local.get 0
    local.get 1
    memory.copy
    i32.const 0)
)
