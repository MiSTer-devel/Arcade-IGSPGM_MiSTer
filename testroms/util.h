#if !defined(UTIL_H)
#define UTIL_H 1

#include <stdint.h>
#include <stddef.h>

static inline size_t strnlen(const char *s, size_t count)
{
	const char *sc = s;
	__asm__ volatile ("\n"
		"1:     subq.l  #1,%1\n"
		"       jcs     2f\n"
		"       tst.b   (%0)+\n"
		"       jne     1b\n"
		"       subq.l  #1,%0\n"
		"2:"
		: "+a" (sc), "+d" (count));
	return sc - s;
}

static inline char *strncpy(char *dest, const char *src, size_t n)
{
	char *xdest = dest;
	__asm__ volatile ("\n"
		"	jra	2f\n"
		"1:	move.b	(%1),(%0)+\n"
		"	jeq	2f\n"
		"	addq.l	#1,%1\n"
		"2:	subq.l	#1,%2\n"
		"	jcc	1b\n"
		: "+a" (dest), "+a" (src), "+d" (n)
		: : "memory");
	return xdest;
}

static inline int strcmp(const char *cs, const char *ct)
{
	char res;
	__asm__ ("\n"
		"1:	move.b	(%0)+,%2\n"	/* get *cs */
		"	cmp.b	(%1)+,%2\n"	/* compare a byte */
		"	jne	2f\n"		/* not equal, break out */
		"	tst.b	%2\n"		/* at end of cs? */
		"	jne	1b\n"		/* no, keep going */
		"	jra	3f\n"		/* strings are equal */
		"2:	sub.b	-(%1),%2\n"	/* *cs - *ct */
		"3:"
		: "+a" (cs), "+a" (ct), "=d" (res));
	return res;
}

void memset(void *ptr, int c, size_t len);
void memcpy(void *a, const void *b, size_t len);
int8_t sin_approx(uint8_t angle);

#endif
