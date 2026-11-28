#pragma once
#include <math.h>
#include <stdint.h>
#include <string.h>
#include <vector>

// Pitch-keeping tempo change for 16-bit stereo PCM (the replay window's rp_ts_* in one piece, for exports).
struct Wsola {
  static const int W = 1536, HS = 768, DL = 480;
  double rate;
  std::vector<float> l, r, acc_l, acc_r, win;
  double pos = 0;
  long nat = -1;

  explicit Wsola(double speed) : rate(speed), acc_l(W, 0.f), acc_r(W, 0.f), win(W) {
    for (int i = 0; i < W; i++) win[i] = (float)(0.5 - 0.5 * cos(6.283185307179586 * i / W));
  }

  float fit(long a, long b) const {
    const float *xl = l.data() + a, *yl = l.data() + b, *xr = r.data() + a, *yr = r.data() + b;
    float xy = 0, xx = 1e-3f;
    for (int j = 0; j < W; j += 2) {
      xy += xl[j] * yl[j] + xr[j] * yr[j];
      xx += xl[j] * xl[j] + xr[j] * xr[j];
    }
    return xy / sqrtf(xx);
  }

  // in: interleaved frames (nullptr feeds silence); out gets interleaved frames appended.
  void feed(const int16_t *in, long frames, bool flush, std::vector<int16_t> &out) {
    for (long i = 0; i < frames; i++) {
      l.push_back(in ? in[2 * i] / 32768.f : 0.f);
      r.push_back(in ? in[2 * i + 1] / 32768.f : 0.f);
    }
    if (flush) {
      l.resize(l.size() + W + HS + 2 * DL, 0.f);
      r.resize(r.size() + W + HS + 2 * DL, 0.f);
    }
    for (;;) {
      long at = (long)pos;
      if (at + DL + HS + W > (long)l.size()) break;
      long seg = at;
      if (nat >= 0) {
        long lo = at - DL < 0 ? 0 : at - DL, hi = at + DL;
        float best = fit(at, nat);
        for (long k = lo; k <= hi; k += 4) {
          float f = fit(k, nat);
          if (f > best) best = f, seg = k;
        }
        long c = seg;
        for (long k = c - 3; k <= c + 3; k++) {
          if (k < lo || k > hi || k == c) continue;
          float f = fit(k, nat);
          if (f > best) best = f, seg = k;
        }
      }
      for (int j = 0; j < W; j++) {
        acc_l[j] += win[j] * l[seg + j];
        acc_r[j] += win[j] * r[seg + j];
      }
      for (int j = 0; j < HS; j++) {
        float a = acc_l[j] * 32767.f, b = acc_r[j] * 32767.f;
        out.push_back((int16_t)(a > 32767.f ? 32767 : (a < -32768.f ? -32768 : a)));
        out.push_back((int16_t)(b > 32767.f ? 32767 : (b < -32768.f ? -32768 : b)));
      }
      memmove(acc_l.data(), acc_l.data() + HS, (W - HS) * sizeof(float));
      memmove(acc_r.data(), acc_r.data() + HS, (W - HS) * sizeof(float));
      for (int j = W - HS; j < W; j++) acc_l[j] = acc_r[j] = 0.f;
      nat = seg + HS;
      pos += HS * rate;
      long drop = (long)pos - DL;
      if (nat < drop) drop = nat;
      if (drop > 8192) {
        l.erase(l.begin(), l.begin() + drop);
        r.erase(r.begin(), r.begin() + drop);
        pos -= drop;
        nat -= drop;
      }
    }
  }
};
