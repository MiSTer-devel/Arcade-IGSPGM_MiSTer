#include <stddef.h>
#include <stdint.h>

static const uint8_t kSinQuarterWave[65] = {
    0, 3, 6, 9, 12, 16, 19, 22,
    25, 28, 31, 34, 37, 40, 43, 46,
    49, 51, 54, 57, 60, 63, 65, 68,
    71, 73, 76, 78, 81, 83, 85, 88,
    90, 92, 94, 96, 98, 100, 102, 104,
    106, 107, 109, 111, 112, 113, 115, 116,
    117, 118, 120, 121, 122, 122, 123, 124,
    125, 125, 126, 126, 126, 127, 127, 127,
    127
};

int8_t sin_approx(uint8_t angle)
{
    const uint8_t quadrant = angle >> 6;
    const uint8_t offset = angle & 0x3f;

    switch (quadrant)
    {
        case 0:
            return (int8_t)kSinQuarterWave[offset];
        case 1:
            return (int8_t)kSinQuarterWave[64 - offset];
        case 2:
            return -(int8_t)kSinQuarterWave[offset];
        default:
            return -(int8_t)kSinQuarterWave[64 - offset];
    }
}

// from linux kernel
void *memset(void *s, int c, size_t count)
{
	void *xs = s;
	size_t temp;
	if (!count)
		return xs;
	c &= 0xff;
	c |= c << 8;
	c |= c << 16;
	if ((long)s & 1) {
		char *cs = s;
		*cs++ = c;
		s = cs;
		count--;
	}
	if (count > 2 && (long)s & 2) {
		short *ss = s;
		*ss++ = c;
		s = ss;
		count -= 2;
	}
	temp = count >> 2;
	if (temp) {
		long *ls = s;
		for (; temp; temp--)
			*ls++ = c;
		s = ls;
	}
	if (count & 2) {
		short *ss = s;
		*ss++ = c;
		s = ss;
	}
	if (count & 1) {
		char *cs = s;
		*cs = c;
	}
	return xs;
}

// from linux kernel
void *memcpy(void *to, const void *from, size_t n)
{
	void *xto = to;
	size_t temp;
	if (!n)
		return xto;
	if ((long)to & 1) {
		char *cto = to;
		const char *cfrom = from;
		*cto++ = *cfrom++;
		to = cto;
		from = cfrom;
		n--;
	}
	if ((long)from & 1) {
		char *cto = to;
		const char *cfrom = from;
		for (; n; n--)
			*cto++ = *cfrom++;
		return xto;
	}
	if (n > 2 && (long)to & 2) {
		short *sto = to;
		const short *sfrom = from;
		*sto++ = *sfrom++;
		to = sto;
		from = sfrom;
		n -= 2;
	}
	temp = n >> 2;
	if (temp) {
		long *lto = to;
		const long *lfrom = from;
		for (; temp; temp--)
			*lto++ = *lfrom++;
		to = lto;
		from = lfrom;
	}
	if (n & 2) {
		short *sto = to;
		const short *sfrom = from;
		*sto++ = *sfrom++;
		to = sto;
		from = sfrom;
	}
	if (n & 1) {
		char *cto = to;
		const char *cfrom = from;
		*cto = *cfrom;
	}
	return xto;
}
