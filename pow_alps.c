#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#ifdef _OPENMP
#include <omp.h>
#endif

#define ROR(x, n) (((x) >> (n)) | ((x) << (64 - (n))))
#define CH(x, y, z) (((x) & (y)) ^ (~(x) & (z)))
#define MAJ(x, y, z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))
#define BSIG0(x) (ROR((x), 28) ^ ROR((x), 34) ^ ROR((x), 39))
#define BSIG1(x) (ROR((x), 14) ^ ROR((x), 18) ^ ROR((x), 41))
#define SSIG0(x) (ROR((x), 1) ^ ROR((x), 8) ^ ((x) >> 7))
#define SSIG1(x) (ROR((x), 19) ^ ROR((x), 61) ^ ((x) >> 6))

static const uint64_t K[80] = {
    0x428a2f98d728ae22ULL, 0x7137449123ef65cdULL, 0xb5c0fbcfec4d3b2fULL,
    0xe9b5dba58189dbbcULL, 0x3956c25bf348b538ULL, 0x59f111f1b605d019ULL,
    0x923f82a4af194f9bULL, 0xab1c5ed5da6d8118ULL, 0xd807aa98a3030242ULL,
    0x12835b0145706fbeULL, 0x243185be4ee4b28cULL, 0x550c7dc3d5ffb4e2ULL,
    0x72be5d74f27b896fULL, 0x80deb1fe3b1696b1ULL, 0x9bdc06a725c71235ULL,
    0xc19bf174cf692694ULL, 0xe49b69c19ef14ad2ULL, 0xefbe4786384f25e3ULL,
    0x0fc19dc68b8cd5b5ULL, 0x240ca1cc77ac9c65ULL, 0x2de92c6f592b0275ULL,
    0x4a7484aa6ea6e483ULL, 0x5cb0a9dcbd41fbd4ULL, 0x76f988da831153b5ULL,
    0x983e5152ee66dfabULL, 0xa831c66d2db43210ULL, 0xb00327c898fb213fULL,
    0xbf597fc7beef0ee4ULL, 0xc6e00bf33da88fc2ULL, 0xd5a79147930aa725ULL,
    0x06ca6351e003826fULL, 0x142929670a0e6e70ULL, 0x27b70a8546d22ffcULL,
    0x2e1b21385c26c926ULL, 0x4d2c6dfc5ac42aedULL, 0x53380d139d95b3dfULL,
    0x650a73548baf63deULL, 0x766a0abb3c77b2a8ULL, 0x81c2c92e47edaee6ULL,
    0x92722c851482353bULL, 0xa2bfe8a14cf10364ULL, 0xa81a664bbc423001ULL,
    0xc24b8b70d0f89791ULL, 0xc76c51a30654be30ULL, 0xd192e819d6ef5218ULL,
    0xd69906245565a910ULL, 0xf40e35855771202aULL, 0x106aa07032bbd1b8ULL,
    0x19a4c116b8d2d0c8ULL, 0x1e376c085141ab53ULL, 0x2748774cdf8eeb99ULL,
    0x34b0bcb5e19b48a8ULL, 0x391c0cb3c5c95a63ULL, 0x4ed8aa4ae3418acbULL,
    0x5b9cca4f7763e373ULL, 0x682e6ff3d6b2b8a3ULL, 0x748f82ee5defb2fcULL,
    0x78a5636f43172f60ULL, 0x84c87814a1f0ab72ULL, 0x8cc702081a6439ecULL,
    0x90befffa23631e28ULL, 0xa4506cebde82bde9ULL, 0xbef9a3f7b2c67915ULL,
    0xc67178f2e372532bULL, 0xca273eceea26619cULL, 0xd186b8c721c0c207ULL,
    0xeada7dd6cde0eb1eULL, 0xf57d4f7fee6ed178ULL, 0x06f067aa72176fbaULL,
    0x0a637dc5a2c898a6ULL, 0x113f9804bef90daeULL, 0x1b710b35131c471bULL,
    0x28db77f523047d84ULL, 0x32caab7b40c72493ULL, 0x3c9ebe0a15c9bebcULL,
    0x431d67c49c100d4cULL, 0x4cc5d4becb3e42b6ULL, 0x597f299cfc657e2aULL,
    0x5fcb6fab3ad6faecULL, 0x6c44198c4a475817ULL};

static int hit(uint64_t c) {
  uint64_t w[80];
  uint16_t a = (uint16_t)(c >> 40);
  uint16_t b = (uint16_t)((c >> 28) & 0xfff);
  uint16_t d = (uint16_t)((c >> 14) & 0x3fff);
  uint16_t e = (uint16_t)(c & 0xffff);

  w[0] = 0xeb36689500000000ULL | ((uint64_t)a << 16) |
         ((uint64_t)(0x4000 | b));
  w[1] = ((uint64_t)(0x8000 | d) << 48) | ((uint64_t)e << 32) |
         0x89a1902aULL;
  w[2] = 0x8000000000000000ULL;
  for (int i = 3; i < 15; i++) w[i] = 0;
  w[15] = 128;
  for (int i = 16; i < 80; i++) {
    w[i] = SSIG1(w[i - 2]) + w[i - 7] + SSIG0(w[i - 15]) + w[i - 16];
  }

  uint64_t A = 0x6a09e667f3bcc908ULL, B = 0xbb67ae8584caa73bULL;
  uint64_t C = 0x3c6ef372fe94f82bULL, D = 0xa54ff53a5f1d36f1ULL;
  uint64_t E = 0x510e527fade682d1ULL, F = 0x9b05688c2b3e6c1fULL;
  uint64_t G = 0x1f83d9abfb41bd6bULL, H = 0x5be0cd19137e2179ULL;

  for (int i = 0; i < 80; i++) {
    uint64_t t1 = H + BSIG1(E) + CH(E, F, G) + K[i] + w[i];
    uint64_t t2 = BSIG0(A) + MAJ(A, B, C);
    H = G; G = F; F = E; E = D + t1;
    D = C; C = B; B = A; A = t1 + t2;
  }

  uint64_t h0 = A + 0x6a09e667f3bcc908ULL;
  return h0 < 0x0000000080000000ULL;
}

int main(int argc, char **argv) {
  uint64_t start = argc > 1 ? strtoull(argv[1], 0, 16) : 0;
  volatile int found = 0;
  uint64_t answer = 0;
  double t0 = (double)clock() / CLOCKS_PER_SEC;

#pragma omp parallel
  {
#ifdef _OPENMP
    int tid = omp_get_thread_num();
    int n = omp_get_num_threads();
#else
    int tid = 0, n = 1;
#endif
    for (uint64_t c = start + tid; !found; c += (uint64_t)n) {
      if (hit(c)) {
        answer = c;
        found = 1;
      }
      if ((c & 0xffffff) == 0 && tid == 0) {
        double now = (double)clock() / CLOCKS_PER_SEC;
        fprintf(stderr, "at %014llx cpu %.1fs\n", (unsigned long long)c, now - t0);
      }
    }
  }

  uint64_t c = answer;
  uint16_t a = (uint16_t)(c >> 40);
  uint16_t b = (uint16_t)((c >> 28) & 0xfff);
  uint16_t d = (uint16_t)((c >> 14) & 0x3fff);
  uint16_t e = (uint16_t)(c & 0xffff);
  printf("eb366895-%04x-4%03x-%04x-%04x89a1902a\n",
         a, b, 0x8000 | d, e);
  return 0;
}
