/* Minimal assertion helpers for host tests. */
#ifndef TEST_H_
#define TEST_H_

#include <stdio.h>
#include <string.h>

extern int test_failures;
extern int test_checks;

#define CHECK(cond)                                                                                \
	do {                                                                                       \
		test_checks++;                                                                     \
		if (!(cond)) {                                                                     \
			test_failures++;                                                           \
			fprintf(stderr, "%s:%d: CHECK(%s) failed\n", __FILE__, __LINE__, #cond);   \
		}                                                                                  \
	} while (0)

#define CHECK_EQ(a, b)                                                                             \
	do {                                                                                       \
		long long a_ = (long long)(a), b_ = (long long)(b);                                \
		test_checks++;                                                                     \
		if (a_ != b_) {                                                                    \
			test_failures++;                                                           \
			fprintf(stderr, "%s:%d: %s == %s failed: %lld != %lld\n", __FILE__,        \
				__LINE__, #a, #b, a_, b_);                                         \
		}                                                                                  \
	} while (0)

#define CHECK_MEM(a, b, n)                                                                         \
	do {                                                                                       \
		test_checks++;                                                                     \
		if (memcmp((a), (b), (n)) != 0) {                                                  \
			test_failures++;                                                           \
			fprintf(stderr, "%s:%d: memcmp(%s, %s) failed\n", __FILE__, __LINE__, #a,  \
				#b);                                                               \
		}                                                                                  \
	} while (0)

#define RUN(fn)                                                                                    \
	do {                                                                                       \
		int before_ = test_failures;                                                       \
		fn();                                                                              \
		printf("%s %s\n", test_failures == before_ ? "ok  " : "FAIL", #fn);               \
	} while (0)

#define TEST_MAIN(body)                                                                            \
	int test_failures;                                                                         \
	int test_checks;                                                                           \
	int main(void)                                                                             \
	{                                                                                          \
		body;                                                                              \
		printf("%d checks, %d failures\n", test_checks, test_failures);                    \
		return test_failures ? 1 : 0;                                                      \
	}

#endif /* TEST_H_ */
