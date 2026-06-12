#if !defined(ICS_REMOTE_PROTOCOL_H)
#define ICS_REMOTE_PROTOCOL_H 1

#define ICS_REMOTE_REQ_MAGIC0 0x49 /* I */
#define ICS_REMOTE_REQ_MAGIC1 0x43 /* C */
#define ICS_REMOTE_RSP_MAGIC0 0x69 /* i */
#define ICS_REMOTE_RSP_MAGIC1 0x63 /* c */
#define ICS_REMOTE_VERSION    0x01
#define ICS_REMOTE_HEADER_SIZE 6
#define ICS_REMOTE_MAX_PAYLOAD 255

#define ICS_REMOTE_STATUS_OK          0x00
#define ICS_REMOTE_STATUS_BAD_MAGIC   0x01
#define ICS_REMOTE_STATUS_BAD_VERSION 0x02
#define ICS_REMOTE_STATUS_BAD_LENGTH  0x03
#define ICS_REMOTE_STATUS_BAD_CMD     0x04
#define ICS_REMOTE_STATUS_ICS_ERROR   0x05

#define ICS_REMOTE_CMD_PING             0x01
#define ICS_REMOTE_CMD_INIT             0x02
#define ICS_REMOTE_CMD_READ_REG         0x10
#define ICS_REMOTE_CMD_WRITE_REG        0x11
#define ICS_REMOTE_CMD_READ_VOICE       0x20
#define ICS_REMOTE_CMD_WRITE_VOICE      0x21
#define ICS_REMOTE_CMD_GET_IRQ_COUNTS   0x30
#define ICS_REMOTE_CMD_RESET_IRQ_COUNTS 0x31
/* payload[0] = reset flag; response = frame_count u32 + 5 x u32 counts */
#define ICS_REMOTE_CMD_GET_IRQ_COUNTS_TIMED 0x32
/* payload[0] = clear flag; response = count u8 + count x {seq,kind,a,b} */
#define ICS_REMOTE_CMD_GET_IRQ_LOG      0x33
/* response = u16 raw ICS status port (0x8000) value */
#define ICS_REMOTE_CMD_READ_STATUS      0x34
/* payload = {addr_hi, addr_lo, len<=64}; 68k reads Z80 RAM over the bus —
 * works even when the Z80 is wedged (post-mortem access to the IRQ log). */
#define ICS_REMOTE_CMD_PEEK_Z80         0x35

#endif
