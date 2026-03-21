// Sony IMU calibration WASM plugin for DualSense / DualShock 4.
// Reads Feature Report 0x05 calibration data in init_device(),
// computes per-axis calibration parameters, and applies them
// each frame in process_report().

#include "padctl_plugin.h"

#define GYRO_RES_PER_DEG_S  1024
#define ACC_RES_PER_G       8192
#define GYRO_RANGE          (2048 * GYRO_RES_PER_DEG_S)
#define ACC_RANGE           (4 * ACC_RES_PER_G)
#define S16_MAX             32767

#define STATE_KEY           "c"
#define STATE_KEY_LEN       1
#define PARAM_BYTES         72  // 18 x i32 = 72

// IMU offsets within USB report (report ID 0x01)
#define GYRO_X_OFF  16
#define GYRO_Y_OFF  18
#define GYRO_Z_OFF  20
#define ACCEL_X_OFF 22
#define ACCEL_Y_OFF 24
#define ACCEL_Z_OFF 26

typedef struct {
    int32_t bias;
    int32_t numer;
    int32_t denom;
} axis_cal_t;

typedef struct {
    axis_cal_t gyro[3];   // pitch, yaw, roll
    axis_cal_t accel[3];  // x, y, z
} cal_params_t;

static int16_t read_i16le(const uint8_t *p) {
    return (int16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static void write_i16le(uint8_t *p, int16_t v) {
    uint16_t u = (uint16_t)v;
    p[0] = (uint8_t)(u & 0xFF);
    p[1] = (uint8_t)(u >> 8);
}

static int32_t mult_frac(int32_t numer, int32_t val, int32_t denom) {
    return (int32_t)(((int64_t)val * numer) / denom);
}

static void parse_calibration(const uint8_t *buf, int32_t len, cal_params_t *cal) {
    if (len < 35) return;

    // Skip byte 0 (report_id).  All values i16le starting at byte 1.
    int16_t gyro_pitch_plus  = read_i16le(buf + 7);
    int16_t gyro_pitch_minus = read_i16le(buf + 9);
    int16_t gyro_yaw_plus    = read_i16le(buf + 11);
    int16_t gyro_yaw_minus   = read_i16le(buf + 13);
    int16_t gyro_roll_plus   = read_i16le(buf + 15);
    int16_t gyro_roll_minus  = read_i16le(buf + 17);
    int16_t gyro_speed_plus  = read_i16le(buf + 19);
    int16_t gyro_speed_minus = read_i16le(buf + 21);

    int16_t accel_x_plus  = read_i16le(buf + 23);
    int16_t accel_x_minus = read_i16le(buf + 25);
    int16_t accel_y_plus  = read_i16le(buf + 27);
    int16_t accel_y_minus = read_i16le(buf + 29);
    int16_t accel_z_plus  = read_i16le(buf + 31);
    int16_t accel_z_minus = read_i16le(buf + 33);

    int32_t speed_2x = (int32_t)gyro_speed_plus + (int32_t)gyro_speed_minus;

    // Gyro: pitch, yaw, roll
    int16_t gp[3] = { gyro_pitch_plus, gyro_yaw_plus, gyro_roll_plus };
    int16_t gm[3] = { gyro_pitch_minus, gyro_yaw_minus, gyro_roll_minus };
    for (int i = 0; i < 3; i++) {
        int32_t denom = (int32_t)gp[i] - (int32_t)gm[i];
        if (denom == 0) {
            cal->gyro[i].bias  = 0;
            cal->gyro[i].numer = GYRO_RANGE;
            cal->gyro[i].denom = S16_MAX;
        } else {
            cal->gyro[i].bias  = 0;
            cal->gyro[i].numer = speed_2x * GYRO_RES_PER_DEG_S;
            cal->gyro[i].denom = denom;
        }
    }

    // Accel: x, y, z
    int16_t ap[3] = { accel_x_plus, accel_y_plus, accel_z_plus };
    int16_t am[3] = { accel_x_minus, accel_y_minus, accel_z_minus };
    for (int i = 0; i < 3; i++) {
        int32_t denom = (int32_t)ap[i] - (int32_t)am[i];
        if (denom == 0) {
            cal->accel[i].bias  = 0;
            cal->accel[i].numer = ACC_RANGE;
            cal->accel[i].denom = S16_MAX;
        } else {
            cal->accel[i].bias  = (int32_t)ap[i] - denom / 2;
            cal->accel[i].numer = 2 * ACC_RES_PER_G;
            cal->accel[i].denom = denom;
        }
    }
}

int32_t init_device(void) {
    uint8_t buf[41];
    int32_t n = device_read(0x05, buf, 41);
    if (n < 41) return -1;

    cal_params_t cal;
    parse_calibration(buf, 41, &cal);
    set_state(STATE_KEY, STATE_KEY_LEN, (const void *)&cal, PARAM_BYTES);
    return 0;
}

void process_calibration(const void *buf, int32_t len) {
    if (len < 41) return;
    cal_params_t cal;
    parse_calibration((const uint8_t *)buf, len, &cal);
    set_state(STATE_KEY, STATE_KEY_LEN, (const void *)&cal, PARAM_BYTES);
}

int32_t process_report(const void *raw, int32_t raw_len,
                       void *out, int32_t out_len) {
    if (raw_len < 30 || out_len < raw_len) return -1;

    // Copy entire report first
    const uint8_t *src = (const uint8_t *)raw;
    uint8_t *dst = (uint8_t *)out;
    for (int32_t i = 0; i < raw_len; i++) dst[i] = src[i];

    // Retrieve calibration state
    cal_params_t cal;
    int32_t got = get_state(STATE_KEY, STATE_KEY_LEN, (void *)&cal, PARAM_BYTES);
    if (got < PARAM_BYTES) return -1; // no calibration data — drop frame

    // IMU base offset from device config; default 16 (USB)
    int32_t imu_off = 16;
    uint8_t cfg_buf[4];
    int32_t cfg_len = get_config("imu_offset", 10, cfg_buf, 4);
    if (cfg_len > 0 && cfg_len <= 4) {
        int32_t v = 0;
        for (int32_t i = 0; i < cfg_len; i++)
            v = v * 10 + (cfg_buf[i] - '0');
        imu_off = v;
    }

    if (raw_len < imu_off + 12) return 0;

    // Apply calibration to 6 axes
    // Gyro: pitch(x), yaw(y), roll(z) — bias is 0
    for (int i = 0; i < 3; i++) {
        int32_t off = imu_off + i * 2;
        int16_t raw_val = read_i16le(src + off);
        int16_t calibrated = (int16_t)mult_frac(cal.gyro[i].numer,
                                                 (int32_t)raw_val - cal.gyro[i].bias,
                                                 cal.gyro[i].denom);
        write_i16le(dst + off, calibrated);
    }

    // Accel: x, y, z — subtract bias first
    for (int i = 0; i < 3; i++) {
        int32_t off = imu_off + 6 + i * 2;
        int16_t raw_val = read_i16le(src + off);
        int16_t calibrated = (int16_t)mult_frac(cal.accel[i].numer,
                                                 (int32_t)raw_val - cal.accel[i].bias,
                                                 cal.accel[i].denom);
        write_i16le(dst + off, calibrated);
    }

    return 0;
}
