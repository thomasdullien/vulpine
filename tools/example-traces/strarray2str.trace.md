Let me analyze the following function carefully:

/*****************************************************************************
 * strarray2str(): convert the array of strings in "a" into a single
 * space-separated string like:
 *        str1 str2 str3
 * If buf is too small, the result will be truncated and end with "...".
 * If include_quotes is non-zero, double quote marks are included around
 * the string, e.g.,
 *        "str2 str2 str3"
 *
 * Returns: 0 if completely successful and -1 if result is truncated.
 */
int
strarray2str(char **a, char *buf, size_t buflen, int include_quotes)
{
    int rc = 0; /* optimistic */
    char *p = buf;
    size_t totlen = 0;
    if (include_quotes) {
        if (buflen < 3) {
            return -1; /* not enough room for the quote marks! */
        }
        *p++ = '"';
        ++totlen;
    }
    if (NULL != a) {
        int ii;
        size_t len = 0;
        for (ii = 0; a[ii] != NULL; ii++) {
            if (ii > 0) {
                *p++ = ' ';
                totlen++;
            }
            len = strlen(s: a[ii]);
            if (totlen + len > buflen - 5) {
                strcpy(dest: p, src: "...");
                p += 3;
                totlen += 3;
                rc = -1;
                break; /* result truncated */
            } else {
                strcpy(dest: p, src: a[ii]);
                p += len;
                totlen += len;
            }
        }
    }
    if (include_quotes) {
        *p++ = '"';
        ++totlen;
    }
    buf[totlen] = '\0';
    return (rc);
}

I will go through the function line-by-line (or a few lines at a time) and I
will add comments that allow me to track the states of the internal variables
and the constraints induced so far by the code. I will mark my observations with
lines prepended by '//!'

int
strarray2str(char **a, char *buf, size_t buflen, int include_quotes)
{
    int rc = 0; /* optimistic */
    char *p = buf;
    size_t totlen = 0;

//! Nothing interesting to see here yet.

    if (include_quotes) {
        if (buflen < 3) {
            return -1; /* not enough room for the quote marks! */
        }

//! Continuing here enforces that if include_quotes is set to true, buflen is
//! necessarily 3 or bigger.

        *p++ = '"';
        ++totlen;

//! The write is safe because buflen is larger than 1.
    }
    if (NULL != a) {
        int ii;
        size_t len = 0;
        for (ii = 0; a[ii] != NULL; ii++) {

//! Ok, the code will iterate over the array of pointers in 'a' until it hits
//! a null pointer, and it increments 'ii' on each iteration.

            if (ii > 0) {
                *p++ = ' ';
                totlen++;
            }

//! Write a space character between tokens, except on the first one.

            len = strlen(s: a[ii]);

//! In theory, strlen() can be zero. Would that cause any issues?

            if (totlen + len > buflen - 5) {

//! Wait. Buflen is under no restriction (except in the include_quotes case,
//! which means that it can be a value that is smaller than 5, for example 4.
//! What happens in that case?
//! For this, we need to look up the types of the variables in question.
//! totlen is size_t
//! len is size_t
//! buflen is size_t
//! These are all unsigned types, so the comparison should end up being
//! unsigned. This will also mean that buflen - 5 should be cast to unsigned,
//! which means that a buflen = 4 should lead to buflen - 5 cast to
//! 0xFFFFFFFFFFFFFFFF. No totlen + len will ever exceed that size, so this
//! would render the range checking entirely invalid?

                strcpy(dest: p, src: "...");
                p += 3;
                totlen += 3;
                rc = -1;
                break; /* result truncated */

//! Ok, if the range check is hit, append three dots (but also a NUL byte?).
//! I think the "5" in the above check is for the three dots, the NUL byte,
//! and a possible closing quote mark.

            } else {
                strcpy(dest: p, src: a[ii]);
                p += len;
                totlen += len;
            }

//! Append the token, increment the counters.
        }
    }
    if (include_quotes) {
        *p++ = '"';
        ++totlen;
    }

//! Write the trailing NUL byte.

    buf[totlen] = '\0';
    return (rc);
}

Ok, this function is dangerously broken if there is any code path that allows
an attacker-influenced buflen - if the attacker chooses a buflen of 3 or 4,
the range checks do not work and memory can be corrupted.

I need to check now if there is any path in the program to call this function
with an attacker-chosen buflen.
