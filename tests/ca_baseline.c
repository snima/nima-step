typedef unsigned long long uint64_t;
typedef unsigned char uint8_t;

uint64_t ca_step_sw(uint64_t state, uint8_t rule, int steps) {
    uint64_t current = state;
    for (int s = 0; s < steps; s++) {
        uint64_t next = 0;
        for (int i = 0; i < 64; i++) {
            int l = (i == 0) ? 63 : i - 1;
            int r = (i == 63) ? 0 : i + 1;
            uint8_t left = (current >> l) & 1;
            uint8_t center = (current >> i) & 1;
            uint8_t right = (current >> r) & 1;
            uint8_t idx = (left << 2) | (center << 1) | right;
            uint8_t new_bit = (rule >> idx) & 1;
            next |= ((uint64_t)new_bit << i);
        }
        current = next;
    }
    return current;
}
