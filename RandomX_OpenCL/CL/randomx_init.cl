/*
Copyright (c) 2019 SChernykh
Portions Copyright (c) 2018-2019 tevador

This file is part of RandomX OpenCL.

RandomX OpenCL is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

RandomX OpenCL is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with RandomX OpenCL. If not, see <http://www.gnu.org/licenses/>.
*/

#include "randomx_constants.h"

#define mantissaSize 52
#define exponentSize 11
#define mantissaMask ((1UL << mantissaSize) - 1)
#define exponentMask ((1UL << exponentSize) - 1)
#define exponentBias 1023

#define dynamicExponentBits 4
#define staticExponentBits 4
#define constExponentBits 0x300
#define dynamicMantissaMask ((1UL << (mantissaSize + dynamicExponentBits)) - 1)

#define CacheLineSize 64U
#define CacheLineAlignMask ((1U << 31) - 1) & ~(CacheLineSize - 1)
#define DatasetExtraItems 524287U

#define ScratchpadL1Mask_reg 38
#define ScratchpadL2Mask_reg 39
#define ScratchpadL3Mask_reg 50

#define ScratchpadL3Mask 2097144

// 12.5*25 = 312.5 bytes on average
#define RANDOMX_FREQ_IADD_RS       25

// 47.5*7 = 332.5 bytes on average
#define RANDOMX_FREQ_IADD_M         7

// 8.5*16 = 136 bytes on average
#define RANDOMX_FREQ_ISUB_R        16

// 47.5*7 = 332.5 bytes on average
#define RANDOMX_FREQ_ISUB_M         7

// 25.5*16 = 408 bytes on average
#define RANDOMX_FREQ_IMUL_R        16

// 63.5*4 = 254 bytes on average
#define RANDOMX_FREQ_IMUL_M         4

// 68*4 = 272 bytes
#define RANDOMX_FREQ_IMULH_R        4

// 107.5*1 = 107.5 bytes on average
#define RANDOMX_FREQ_IMULH_M        1

// 100*4 = 400 bytes
#define RANDOMX_FREQ_ISMULH_R       4

// 139.5*1 = 139.5 bytes on average
#define RANDOMX_FREQ_ISMULH_M       1

// 36*8 = 288 bytes
#define RANDOMX_FREQ_IMUL_RCP       8

// 8*2 = 16 bytes
#define RANDOMX_FREQ_INEG_R         2

// 5.5*15 = 82.5 bytes
#define RANDOMX_FREQ_IXOR_R        15

// 43.5*5 = 217.5 bytes on average
#define RANDOMX_FREQ_IXOR_M         5

// 15.5*10 = 155 bytes on average
#define RANDOMX_FREQ_IROR_R        10

// 10.5*4 = 42 bytes on average
#define RANDOMX_FREQ_ISWAP_R        4

// 28*16 = 448 bytes
#define RANDOMX_FREQ_ISTORE        16

// Total: 3943.5 + 4(s_setpc_b64) = 3947.5 bytes on average

ulong getSmallPositiveFloatBits(const ulong entropy)
{
	ulong exponent = entropy >> 59;
	ulong mantissa = entropy & mantissaMask;
	exponent += exponentBias;
	exponent &= exponentMask;
	exponent <<= mantissaSize;
	return exponent | mantissa;
}

ulong getStaticExponent(const ulong entropy)
{
	ulong exponent = constExponentBits;
	exponent |= (entropy >> (64 - staticExponentBits)) << dynamicExponentBits;
	exponent <<= mantissaSize;
	return exponent;
}

ulong getFloatMask(const ulong entropy)
{
	const uint mask22bit = (1U << 22) - 1;
	return (entropy & mask22bit) | getStaticExponent(entropy);
}

__global uint* jit_scratchpad_calc_address(__global uint* p, uint src, uint imm32, uint mask_reg, uint batch_size)
{
	// s_add_i32 s14, s(16 + src * 2), imm32
	*(p++) = 0x810eff10u | (src << 1);
	*(p++) = imm32;

	// v_and_b32 v28, s14, mask_reg
	*(p++) = 0x2638000eu | (mask_reg << 9);

#if SCRATCHPAD_STRIDED == 1
	// v_and_b32 v29, s14, 56
	*(p++) = 0xd113001du;
	*(p++) = 0x0001700eu;

	// s3 = batch_size
	// v_mad_u32_u24 v28, v28, s3, v29
	*(p++) = 0xd1c3001cu;
	*(p++) = 0x0474071cu;
#endif

	return p;
}

__global uint* jit_scratchpad_calc_fixed_address(__global uint* p, uint imm32, uint batch_size)
{
#if SCRATCHPAD_STRIDED == 1
	imm32 = mad24(imm32 & ~63u, batch_size, imm32 & 56);
#endif

	// v_mov_b32 v28, imm32
	*(p++) = 0x7e3802ffu;
	*(p++) = imm32;

	return p;
}

__global uint* jit_scratchpad_load(__global uint* p, uint lane_index, uint vgpr_index)
{
	// v28 = offset
	// global_load_dwordx2 v[vgpr_index:vgpr_index+1], v28, s[0:1]
	*(p++) = 0xdc548000u;
	*(p++) = 0x0000001cu | (vgpr_index << 24);

	return p;
}

__global uint* jit_scratchpad_load2(__global uint* p, uint lane_index, uint vgpr_index, int vmcnt)
{
	// s_waitcnt vmcnt(N)
	if (vmcnt >= 0)
		*(p++) = 0xbf8c0f70u | (vmcnt & 15) | ((vmcnt >> 4) << 14);

	// v_readlane_b32 s14, vgpr_index, lane_index * 16
	*(p++) = 0xd289000eu;
	*(p++) = 0x00010100u | (lane_index << 13) | vgpr_index;

	// v_readlane_b32 s15, vgpr_index + 1, lane_index * 16
	*(p++) = 0xd289000fu;
	*(p++) = 0x00010100u | (lane_index << 13) | (vgpr_index + 1);

	return p;
}

ulong imul_rcp_value(uint divisor)
{
	const ulong p2exp63 = 1ULL << 63;

	ulong quotient = p2exp63 / divisor;
	ulong remainder = p2exp63 % divisor;

	const uint bsr = 31 - clz(divisor);

	for (uint shift = 0; shift <= bsr; ++shift)
	{
		const bool b = (remainder >= divisor - remainder);
		quotient = (quotient << 1) | (b ? 1 : 0);
		remainder = (remainder << 1) - (b ? divisor : 0);
	}

	return quotient;
}

__global uint* jit_emit_instruction(__global uint* p, const uint2 inst, int prefetch_vgpr_index, int vmcnt, uint lane_index, uint batch_size)
{
	uint opcode = inst.x & 0xFF;
	const uint dst = (inst.x >> 8) & 7;
	const uint src = (inst.x >> 16) & 7;
	const uint mod = inst.x >> 24;

	if (opcode < RANDOMX_FREQ_IADD_RS)
	{
		const uint shift = (mod >> 2) % 4;
		if (shift > 0) // p = 3/4
		{
			// s_lshl_b64 s[14:15], s[(16 + src * 2):(17 + src * 2)], shift
			*(p++) = 0x8e8e8010u | (src << 1) | (shift << 8);

			// s_add_u32 s(16 + dst * 2), s(16 + dst * 2), s14
			*(p++) = 0x80100e10u | (dst << 1) | (dst << 17);

			// s_addc_u32 s(17 + dst * 2), s(17 + dst * 2), s15
			*(p++) = 0x82110f11u | (dst << 1) | (dst << 17);
		}
		else // p = 1/4
		{
			// s_add_u32 s(16 + dst * 2), s(16 + dst * 2), s(16 + src * 2)
			*(p++) = 0x80101010u | (dst << 1) | (dst << 17) | (src << 9);

			// s_addc_u32 s(17 + dst * 2), s(17 + dst * 2), s(17 + src * 2)
			*(p++) = 0x82111111u | (dst << 1) | (dst << 17) | (src << 9);
		}

		if (dst == 5) // p = 1/8
		{
			// s_add_u32 s(16 + dst * 2), s(16 + dst * 2), imm32
			*(p++) = 0x8010ff10u | (dst << 1) | (dst << 17);
			*(p++) = inst.y;

			// s_addc_u32 s(17 + dst * 2), s(17 + dst * 2), ((inst.y < 0) ? -1 : 0)
			*(p++) = 0x82110011u | (dst << 1) | (dst << 17) | (((as_int(inst.y) < 0) ? 0xc1 : 0x80) << 8);
		}

		// 12*3/4 + 8*1/4 + 12/8 = 12.5 bytes on average
		return p;
	}
	opcode -= RANDOMX_FREQ_IADD_RS;

	if (opcode < RANDOMX_FREQ_IADD_M)
	{
		if (prefetch_vgpr_index >= 0)
		{
			if (src != dst) // p = 7/8
				p = jit_scratchpad_calc_address(p, src, inst.y, (mod % 4) ? ScratchpadL1Mask_reg : ScratchpadL2Mask_reg, batch_size);
			else // p = 1/8
				p = jit_scratchpad_calc_fixed_address(p, inst.y & ScratchpadL3Mask, batch_size);

			p = jit_scratchpad_load(p, lane_index, prefetch_vgpr_index ? prefetch_vgpr_index : 28);
		}

		if (prefetch_vgpr_index <= 0)
		{
			p = jit_scratchpad_load2(p, lane_index, prefetch_vgpr_index ? -prefetch_vgpr_index : 28, prefetch_vgpr_index ? vmcnt : 0);

			// s_add_u32 s(16 + dst * 2), s(16 + dst * 2), s14
			*(p++) = 0x80100e10u | (dst << 1) | (dst << 17);

			// s_addc_u32 s(17 + dst * 2), s(17 + dst * 2), s15
			*(p++) = 0x82110f11u | (dst << 1) | (dst << 17);
		}

		// (12*7/8 + 8*1/8 + 28) + 8 = 47.5 bytes on average
		return p;
	}
	opcode -= RANDOMX_FREQ_IADD_M;

	if (opcode < RANDOMX_FREQ_ISUB_R)
	{
		if (src != dst) // p = 7/8
		{
			// s_sub_u32 s(16 + dst * 2), s(16 + dst * 2), s(16 + src * 2)
			*(p++) = 0x80901010u | (dst << 1) | (dst << 17) | (src << 9);

			// s_subb_u32 s(17 + dst * 2), s(17 + dst * 2), s(17 + src * 2)
			*(p++) = 0x82911111u | (dst << 1) | (dst << 17) | (src << 9);
		}
		else // p = 1/8
		{
			// s_sub_u32 s(16 + dst * 2), s(16 + dst * 2), imm32
			*(p++) = 0x8090ff10u | (dst << 1) | (dst << 17);
			*(p++) = inst.y;

			// s_subb_u32 s(17 + dst * 2), s(17 + dst * 2), ((inst.y < 0) ? -1 : 0)
			*(p++) = 0x82910011u | (dst << 1) | (dst << 17) | (((as_int(inst.y) < 0) ? 0xc1 : 0x80) << 8);
		}

		// 8*7/8 + 12/8 = 8.5 bytes on average
		return p;
	}
	opcode -= RANDOMX_FREQ_ISUB_R;

	if (opcode < RANDOMX_FREQ_ISUB_M)
	{
		if (prefetch_vgpr_index >= 0)
		{
			if (src != dst) // p = 7/8
				p = jit_scratchpad_calc_address(p, src, inst.y, (mod % 4) ? ScratchpadL1Mask_reg : ScratchpadL2Mask_reg, batch_size);
			else // p = 1/8
				p = jit_scratchpad_calc_fixed_address(p, inst.y & ScratchpadL3Mask, batch_size);

			p = jit_scratchpad_load(p, lane_index, prefetch_vgpr_index ? prefetch_vgpr_index : 28);
		}

		if (prefetch_vgpr_index <= 0)
		{
			p = jit_scratchpad_load2(p, lane_index, prefetch_vgpr_index ? -prefetch_vgpr_index : 28, prefetch_vgpr_index ? vmcnt : 0);

			// s_sub_u32 s(16 + dst * 2), s(16 + dst * 2), s14
			*(p++) = 0x80900e10u | (dst << 1) | (dst << 17);

			// s_subb_u32 s(17 + dst * 2), s(17 + dst * 2), s15
			*(p++) = 0x82910f11u | (dst << 1) | (dst << 17);
		}

		// (12*7/8 + 8*1/8 + 28) + 8 = 47.5 bytes on average
		return p;
	}
	opcode -= RANDOMX_FREQ_ISUB_M;

	if (opcode < RANDOMX_FREQ_IMUL_R)
	{
		if (src != dst) // p = 7/8
		{
			// s_mul_hi_u32 s15, s(16 + dst * 2), s(16 + src * 2)
			*(p++) = 0x960f1010u | (dst << 1) | (src << 9);

			// s_mul_i32 s14, s(16 + dst * 2), s(17 + src * 2)
			*(p++) = 0x920e1110u | (dst << 1) | (src << 9);

			// s_add_u32 s15, s15, s14
			*(p++) = 0x800f0e0fu;

			// s_mul_i32 s14, s(17 + dst * 2), s(16 + src * 2)
			*(p++) = 0x920e1011u | (dst << 1) | (src << 9);

			// s_add_u32 s(17 + dst * 2), s15, s14
			*(p++) = 0x80110e0fu | (dst << 17);

			// s_mul_i32 s(16 + dst * 2), s(16 + dst * 2), s(16 + src * 2)
			*(p++) = 0x92101010u | (dst << 1) | (dst << 17) | (src << 9);
		}
		else // p = 1/8
		{
			// s_mul_hi_u32 s15, s(16 + dst * 2), imm32
			*(p++) = 0x960fff10u | (dst << 1);
			*(p++) = inst.y;

			// s_mul_i32 s14, s16, (imm32 < 0) ? -1 : 0
			*(p++) = 0x920e0010u | (dst << 1) | ((as_int(inst.y) < 0) ? 0xc100 : 0x8000);

			// s_add_u32 s15, s15, s14
			*(p++) = 0x800f0e0fu;

			// s_mul_i32 s14, s(17 + dst * 2), imm32
			*(p++) = 0x920eff11u | (dst << 1);
			*(p++) = inst.y;

			// s_add_u32 s(17 + dst * 2), s15, s14
			*(p++) = 0x80110e0fu | (dst << 17);

			// s_mul_i32 s(16 + dst * 2), s(16 + dst * 2), imm32
			*(p++) = 0x9210ff10u | (dst << 1) | (dst << 17);
			*(p++) = inst.y;
		}

		// 24*7/8 + 36*1/8 = 25.5 bytes on average
		return p;
	}
	opcode -= RANDOMX_FREQ_IMUL_R;

	if (opcode < RANDOMX_FREQ_IMUL_M)
	{
		if (prefetch_vgpr_index >= 0)
		{
			if (src != dst) // p = 7/8
				p = jit_scratchpad_calc_address(p, src, inst.y, (mod % 4) ? ScratchpadL1Mask_reg : ScratchpadL2Mask_reg, batch_size);
			else // p = 1/8
				p = jit_scratchpad_calc_fixed_address(p, inst.y & ScratchpadL3Mask, batch_size);

			p = jit_scratchpad_load(p, lane_index, prefetch_vgpr_index ? prefetch_vgpr_index : 28);
		}

		if (prefetch_vgpr_index <= 0)
		{
			p = jit_scratchpad_load2(p, lane_index, prefetch_vgpr_index ? -prefetch_vgpr_index : 28, prefetch_vgpr_index ? vmcnt : 0);

			// s_mul_hi_u32 s33, s(16 + dst * 2), s14
			*(p++) = 0x96210e10u | (dst << 1);

			// s_mul_i32 s32, s(16 + dst * 2), s15
			*(p++) = 0x92200f10u | (dst << 1);

			// s_add_u32 s33, s33, s32
			*(p++) = 0x80212021u;

			// s_mul_i32 s32, s(17 + dst * 2), s14
			*(p++) = 0x92200e11u | (dst << 1);

			// s_add_u32 s(17 + dst * 2), s33, s32
			*(p++) = 0x80112021u | (dst << 17);

			// s_mul_i32 s(16 + dst * 2), s(16 + dst * 2), s14
			*(p++) = 0x92100e10u | (dst << 1) | (dst << 17);
		}

		// (12*7/8 + 8*1/8 + 28) + 24 = 63.5 bytes on average
		return p;
	}
	opcode -= RANDOMX_FREQ_IMUL_M;

	if (opcode < RANDOMX_FREQ_IMULH_R)
	{
		*(p++) = 0x7e5a0210u | (dst << 1);			// v_mov_b32       v45, s(16 + dst * 2)
		*(p++) = 0xd2860028u;						// v_mul_hi_u32    v40, s(16 + src * 2), v45
		*(p++) = 0x00025a10u | (src << 1);
		*(p++) = 0x7e5e0211u | (dst << 1);			// v_mov_b32       v47, s(17 + dst * 2)
		*(p++) = 0xd1e8202au;						// v_mad_u64_u32   v[42:43], s[32:33], s(16 + src * 2), v47, v[40:41]
		*(p++) = 0x04a25e10u | (src << 1);
		*(p++) = 0x7e50032au;						// v_mov_b32       v40, v42
		*(p++) = 0xd1e8202du;						// v_mad_u64_u32   v[45:46], s[32:33], s(17 + src * 2), v45, v[40:41]
		*(p++) = 0x04a25a11u | (src << 1);
		*(p++) = 0xd1e8202au;						// v_mad_u64_u32   v[42:43], s[32:33], s(17 + src * 2), v47, v[43:44]
		*(p++) = 0x04ae5e11u | (src << 1);
		*(p++) = 0x32545d2au;						// v_add_co_u32    v42, vcc, v42, v46
		*(p++) = 0x38565680u;						// v_addc_co_u32   v43, vcc, 0, v43, vcc
		*(p++) = 0xd2890010u | (dst << 1);			// v_readlane_b32  s(16 + dst * 2), v42, lane_index * 16
		*(p++) = 0x0001012au | (lane_index << 13);
		*(p++) = 0xd2890011u | (dst << 1);			// v_readlane_b32  s(17 + dst * 2), v43, lane_index * 16
		*(p++) = 0x0001012bu | (lane_index << 13);

		// 68 bytes
		return p;
	}
	opcode -= RANDOMX_FREQ_IMULH_R;

	if (opcode < RANDOMX_FREQ_IMULH_M)
	{
		if (prefetch_vgpr_index >= 0)
		{
			if (src != dst) // p = 7/8
				p = jit_scratchpad_calc_address(p, src, inst.y, (mod % 4) ? ScratchpadL1Mask_reg : ScratchpadL2Mask_reg, batch_size);
			else // p = 1/8
				p = jit_scratchpad_calc_fixed_address(p, inst.y & ScratchpadL3Mask, batch_size);

			p = jit_scratchpad_load(p, lane_index, prefetch_vgpr_index ? prefetch_vgpr_index : 28);
		}

		if (prefetch_vgpr_index <= 0)
		{
			p = jit_scratchpad_load2(p, lane_index, prefetch_vgpr_index ? -prefetch_vgpr_index : 28, prefetch_vgpr_index ? vmcnt : 0);

			*(p++) = 0x7e5a0210u | (dst << 1);			// v_mov_b32       v45, s(16 + dst * 2)
			*(p++) = 0xd2860028u;						// v_mul_hi_u32    v40, s14, v45
			*(p++) = 0x00025a0eu;
			*(p++) = 0x7e5e0211u | (dst << 1);			// v_mov_b32       v47, s(17 + dst * 2)
			*(p++) = 0xd1e8202au;						// v_mad_u64_u32   v[42:43], s[32:33], s14, v47, v[40:41]
			*(p++) = 0x04a25e0eu;
			*(p++) = 0x7e50032au;						// v_mov_b32       v40, v42
			*(p++) = 0xd1e8202du;						// v_mad_u64_u32   v[45:46], s[32:33], s15, v45, v[40:41]
			*(p++) = 0x04a25a0fu;
			*(p++) = 0xd1e8202au;						// v_mad_u64_u32   v[42:43], s[32:33], s15, v47, v[43:44]
			*(p++) = 0x04ae5e0fu;
			*(p++) = 0x32545d2au;						// v_add_co_u32    v42, vcc, v42, v46
			*(p++) = 0x38565680u;						// v_addc_co_u32   v43, vcc, 0, v43, vcc
			*(p++) = 0xd2890010u | (dst << 1);			// v_readlane_b32  s(16 + dst * 2), v42, lane_index * 16
			*(p++) = 0x0001012au | (lane_index << 13);
			*(p++) = 0xd2890011u | (dst << 1);			// v_readlane_b32  s(17 + dst * 2), v43, lane_index * 16
			*(p++) = 0x0001012bu | (lane_index << 13);
		}

		// (12*7/8 + 8*1/8 + 28) + 68 = 107.5 bytes on average
		return p;
	}
	opcode -= RANDOMX_FREQ_IMULH_M;

	if (opcode < RANDOMX_FREQ_ISMULH_R)
	{
		*(p++) = 0x7e5a0210u | (dst << 1);			// v_mov_b32       v45, s(16 + dst * 2)
		*(p++) = 0xd2860028u;						// v_mul_hi_u32    v40, s(16 + src * 2), v45
		*(p++) = 0x00025a10u | (src << 1);
		*(p++) = 0x7e5e0211u | (dst << 1);			// v_mov_b32       v47, s(17 + dst * 2)
		*(p++) = 0xd1e8202au;						// v_mad_u64_u32   v[42:43], s[32:33], s(16 + src * 2), v47, v[40:41]
		*(p++) = 0x04a25e10u | (src << 1);
		*(p++) = 0x7e50032au;						// v_mov_b32       v40, v42
		*(p++) = 0xd1e8202du;						// v_mad_u64_u32   v[45:46], s[32:33], s(17 + src * 2), v45, v[40:41]
		*(p++) = 0x04a25a11u | (src << 1);
		*(p++) = 0xd1e8202au;						// v_mad_u64_u32   v[42:43], s[32:33], s(17 + src * 2), v47, v[43:44]
		*(p++) = 0x04ae5e11u | (src << 1);
		*(p++) = 0x32545d2au;						// v_add_co_u32    v42, vcc, v42, v46
		*(p++) = 0x38565680u;						// v_addc_co_u32   v43, vcc, 0, v43, vcc
		*(p++) = 0xd2890020u;						// v_readlane_b32  s32, v42, lane_index * 16
		*(p++) = 0x0001012au | (lane_index << 13);
		*(p++) = 0xd2890021u;						// v_readlane_b32  s33, v43, lane_index * 16
		*(p++) = 0x0001012bu | (lane_index << 13);
		*(p++) = 0xbf048011u | (dst << 1);			// s_cmp_lt_i32    s(17 + dst * 2), 0
		*(p++) = 0x85a28010u | (src << 1);			// s_cselect_b64   s[34:35], s[16 + src * 2:17 + src * 2], 0
		*(p++) = 0x80a02220u;						// s_sub_u32       s32, s32, s34
		*(p++) = 0x82a12321u;						// s_subb_u32      s33, s33, s35
		*(p++) = 0xbf048011u | (src << 1);			// s_cmp_lt_i32    s(17 + src * 2), 0
		*(p++) = 0x85a28010u | (dst << 1);			// s_cselect_b64   s[34:35], s[16 + dst * 2:17 + dst * 2], 0
		*(p++) = 0x80902220u | (dst << 17);			// s_sub_u32       s(16 + dst * 2), s32, s34
		*(p++) = 0x82912321u | (dst << 17);			// s_subb_u32      s(17 + dst * 2), s33, s35

		// 100 bytes
		return p;
	}
	opcode -= RANDOMX_FREQ_ISMULH_R;

	if (opcode < RANDOMX_FREQ_ISMULH_M)
	{
		if (prefetch_vgpr_index >= 0)
		{
			if (src != dst) // p = 7/8
				p = jit_scratchpad_calc_address(p, src, inst.y, (mod % 4) ? ScratchpadL1Mask_reg : ScratchpadL2Mask_reg, batch_size);
			else // p = 1/8
				p = jit_scratchpad_calc_fixed_address(p, inst.y & ScratchpadL3Mask, batch_size);

			p = jit_scratchpad_load(p, lane_index, prefetch_vgpr_index ? prefetch_vgpr_index : 28);
		}

		if (prefetch_vgpr_index <= 0)
		{
			p = jit_scratchpad_load2(p, lane_index, prefetch_vgpr_index ? -prefetch_vgpr_index : 28, prefetch_vgpr_index ? vmcnt : 0);

			*(p++) = 0x7e5a0210u | (dst << 1);			// v_mov_b32       v45, s(16 + dst * 2)
			*(p++) = 0xd2860028u;						// v_mul_hi_u32    v40, s14, v45
			*(p++) = 0x00025a0eu;
			*(p++) = 0x7e5e0211u | (dst << 1);			// v_mov_b32       v47, s(17 + dst * 2)
			*(p++) = 0xd1e8202au;						// v_mad_u64_u32   v[42:43], s[32:33], s14, v47, v[40:41]
			*(p++) = 0x04a25e0eu;
			*(p++) = 0x7e50032au;						// v_mov_b32       v40, v42
			*(p++) = 0xd1e8202du;						// v_mad_u64_u32   v[45:46], s[32:33], s15, v45, v[40:41]
			*(p++) = 0x04a25a0fu;
			*(p++) = 0xd1e8202au;						// v_mad_u64_u32   v[42:43], s[32:33], s15, v47, v[43:44]
			*(p++) = 0x04ae5e0fu;
			*(p++) = 0x32545d2au;						// v_add_co_u32    v42, vcc, v42, v46
			*(p++) = 0x38565680u;						// v_addc_co_u32   v43, vcc, 0, v43, vcc
			*(p++) = 0xd2890020u;						// v_readlane_b32  s32, v42, lane_index * 16
			*(p++) = 0x0001012au | (lane_index << 13);
			*(p++) = 0xd2890021u;						// v_readlane_b32  s33, v43, lane_index * 16
			*(p++) = 0x0001012bu | (lane_index << 13);
			*(p++) = 0xbf048011u | (dst << 1);			// s_cmp_lt_i32    s(17 + dst * 2), 0
			*(p++) = 0x85a2800eu;						// s_cselect_b64   s[34:35], s[14:15], 0
			*(p++) = 0x80a02220u;						// s_sub_u32       s32, s32, s34
			*(p++) = 0x82a12321u;						// s_subb_u32      s33, s33, s35
			*(p++) = 0xbf04800fu;						// s_cmp_lt_i32    s15, 0
			*(p++) = 0x85a28010u | (dst << 1);			// s_cselect_b64   s[34:35], s[16 + dst * 2:17 + dst * 2], 0
			*(p++) = 0x80902220u | (dst << 17);			// s_sub_u32       s(16 + dst * 2), s32, s34
			*(p++) = 0x82912321u | (dst << 17);			// s_subb_u32      s(17 + dst * 2), s33, s35
		}

		// (12*7/8 + 8*1/8 + 28) + 100 = 139.5 bytes on average
		return p;
	}
	opcode -= RANDOMX_FREQ_ISMULH_M;

	if (opcode < RANDOMX_FREQ_IMUL_RCP)
	{
		if (inst.y & (inst.y - 1))
		{
			const uint2 rcp_value = as_uint2(imul_rcp_value(inst.y));

			*(p++) = 0xbea000ffu;							// s_mov_b32       s32, imm32
			*(p++) = rcp_value.x;
			*(p++) = 0x960f2010u | (dst << 1);				// s_mul_hi_u32    s15, s(16 + dst * 2), s32
			*(p++) = 0x920eff10u | (dst << 1);				// s_mul_i32       s14, s(16 + dst * 2), imm32
			*(p++) = rcp_value.y;
			*(p++) = 0x800f0e0fu;							// s_add_u32       s15, s15, s14
			*(p++) = 0x920e2011u | (dst << 1);				// s_mul_i32       s14, s(17 + dst * 2), s32
			*(p++) = 0x80110e0fu | (dst << 17);				// s_add_u32       s(17 + dst * 2), s15, s14
			*(p++) = 0x92102010u | (dst << 1) | (dst << 17);// s_mul_i32       s(16 + dst * 2), s(16 + dst * 2), s32
		}

		// 36 bytes
		return p;
	}
	opcode -= RANDOMX_FREQ_IMUL_RCP;

	if (opcode < RANDOMX_FREQ_INEG_R)
	{
		*(p++) = 0x80901080u | (dst << 9) | (dst << 17);	// s_sub_u32       s(16 + dst * 2), 0, s(16 + dst * 2)
		*(p++) = 0x82911180u | (dst << 9) | (dst << 17);	// s_subb_u32      s(17 + dst * 2), 0, s(17 + dst * 2)

		// 8 bytes
		return p;
	}
	opcode -= RANDOMX_FREQ_INEG_R;

	if (opcode < RANDOMX_FREQ_IXOR_R)
	{
		if (src != dst) // p = 7/8
		{
			// s_xor_b64 s[16 + dst * 2:17 + dst * 2], s[16 + dst * 2:17 + dst * 2], s[16 + src * 2:17 + src * 2]
			*(p++) = 0x88901010u | (dst << 1) | (dst << 17) | (src << 9);
		}
		else // p = 1/8
		{
			// s_mov_b32 s32, imm32
			*(p++) = 0xbea000ffu;
			*(p++) = inst.y;

			// s_mov_b32 s33, (inst.y < 0) ? -1 : 0
			*(p++) = 0xbea10000u | ((as_int(inst.y) < 0) ? 0xc1 : 0x80);

			// s_xor_b64 s[16 + dst * 2:17 + dst * 2], s[16 + dst * 2:17 + dst * 2], s[32:33]
			*(p++) = 0x88902010u | (dst << 1) | (dst << 17);
		}

		// 4*7/8 + 16/8 = 5.5 bytes on average
		return p;
	}
	opcode -= RANDOMX_FREQ_IXOR_R;

	if (opcode < RANDOMX_FREQ_IXOR_M)
	{
		if (prefetch_vgpr_index >= 0)
		{
			if (src != dst) // p = 7/8
				p = jit_scratchpad_calc_address(p, src, inst.y, (mod % 4) ? ScratchpadL1Mask_reg : ScratchpadL2Mask_reg, batch_size);
			else // p = 1/8
				p = jit_scratchpad_calc_fixed_address(p, inst.y & ScratchpadL3Mask, batch_size);

			p = jit_scratchpad_load(p, lane_index, prefetch_vgpr_index ? prefetch_vgpr_index : 28);
		}

		if (prefetch_vgpr_index <= 0)
		{
			p = jit_scratchpad_load2(p, lane_index, prefetch_vgpr_index ? -prefetch_vgpr_index : 28, prefetch_vgpr_index ? vmcnt : 0);

			// s_xor_b64 s[16 + dst * 2:17 + dst * 2], s[16 + dst * 2:17 + dst * 2], s[14:15]
			*(p++) = 0x88900e10u | (dst << 1) | (dst << 17);
		}

		// (12*7/8 + 8*1/8 + 28) + 4 = 43.5 bytes on average
		return p;
	}
	opcode -= RANDOMX_FREQ_IXOR_M;

	if (opcode < RANDOMX_FREQ_IROR_R)
	{
		if (src != dst) // p = 7/8
		{
			// s_lshr_b64 s[32:33], s[16 + dst * 2:17 + dst * 2], s(16 + src * 2)
			*(p++) = 0x8fa01010u | (dst << 1) | (src << 9);

			// s_sub_u32  s15, 64, s(16 + src * 2)
			*(p++) = 0x808f10c0u | (src << 9);

			// s_lshl_b64 s[34:35], s[16 + dst * 2:17 + dst * 2], s15
			*(p++) = 0x8ea20f10u | (dst << 1);
		}
		else // p = 1/8
		{
			const uint shift = inst.y & 63;

			// s_lshr_b64 s[32:33], s[16 + dst * 2:17 + dst * 2], shift
			*(p++) = 0x8fa08010u | (dst << 1) | (shift << 8);

			// s_lshl_b64 s[34:35], s[16 + dst * 2:17 + dst * 2], 64 - shift
			*(p++) = 0x8ea28010u | (dst << 1) | ((64 - shift) << 8);
		}

		// s_or_b64 s[16 + dst * 2:17 + dst * 2], s[32:33], s[34:35]
		*(p++) = 0x87902220u | (dst << 17);

		// 12*7/8 + 8/8 + 4 = 15.5 bytes on average
		return p;
	}
	opcode -= RANDOMX_FREQ_IROR_R;

	if (opcode < RANDOMX_FREQ_ISWAP_R)
	{
		if (src != dst)
		{
			*(p++) = 0xbea00110u | (dst << 1);				// s_mov_b64       s[32:33], s[16 + dst * 2:17 + dst * 2]
			*(p++) = 0xbe900110u | (src << 1) | (dst << 17);// s_mov_b64       s[16 + dst * 2:17 + dst * 2], s[16 + src * 2:17 + src * 2]
			*(p++) = 0xbe900120u | (src << 17);				// s_mov_b64       s[16 + src * 2:17 + Src * 2], s[32:33]
		}

		// 12*7/8 = 10.5 bytes on average
		return p;
	}
	opcode -= RANDOMX_FREQ_ISWAP_R;

	if (opcode < RANDOMX_FREQ_ISTORE)
	{
		const uint mask = ((mod >> 4) < 14) ? ((mod % 4) ? ScratchpadL1Mask_reg : ScratchpadL2Mask_reg) : ScratchpadL3Mask_reg;
		p = jit_scratchpad_calc_address(p, dst, inst.y, mask, batch_size);

		const uint vgpr_id = 48;
		*(p++) = 0x7e000210u | (src << 1) | (vgpr_id << 17);	// v_mov_b32       vgpr_id, s(16 + src * 2)
		*(p++) = 0x7e020211u | (src << 1) | (vgpr_id << 17);	// v_mov_b32       vgpr_id + 1, s(17 + src * 2)

		// v28 = offset
		// global_store_dwordx2 v28, v[vgpr_id:vgpr_id + 1], s[0:1]
		*(p++) = 0xdc748000u;
		*(p++) = 0x0000001cu | (vgpr_id << 8);

		// 28 bytes
		return p;
	}
	opcode -= RANDOMX_FREQ_ISTORE;

	return p;
}

__global uint* generate_jit_code(__global uint2* e, __global uint2* p0, __global uint* p, uint lane_index, uint batch_size)
{
	ulong registerLastChanged = 0;
	uint registerWasChanged = 0;

	uint scratchpadAvailableAt = 0;
	uint scratchpadHighAvailableAt = 0;

	int prefetch_data_count = 0;
	#pragma unroll(1)
	for (uint i = 0; i < RANDOMX_PROGRAM_SIZE; ++i)
	{
		// Clean flags
		e[i].x &= ~(0xf8u << 8);

		uint2 inst = e[i];
		uint opcode = inst.x & 0xFF;
		const uint dst = (inst.x >> 8) & 7;
		const uint src = (inst.x >> 16) & 7;
		const uint mod = inst.x >> 24;

		const uint srcAvailableAt = (registerWasChanged & (1u << src)) ? (((registerLastChanged >> (src * 8)) & 0xFF) + 1) : 0;
		const uint dstAvailableAt = (registerWasChanged & (1u << dst)) ? (((registerLastChanged >> (dst * 8)) & 0xFF) + 1) : 0;

		if (opcode < RANDOMX_FREQ_IADD_RS)
		{
			registerLastChanged = (registerLastChanged & ~(0xFFul << (dst * 8))) | ((ulong)(i) << (dst * 8));
			registerWasChanged |= 1u << dst;
			continue;
		}
		opcode -= RANDOMX_FREQ_IADD_RS;

		if (opcode < RANDOMX_FREQ_IADD_M)
		{
			registerLastChanged = (registerLastChanged & ~(0xFFul << (dst * 8))) | ((ulong)(i) << (dst * 8));
			registerWasChanged |= 1u << dst;
			inst.x = (src == dst) ? (((inst.y & ScratchpadL3Mask) >= 262144) ? scratchpadHighAvailableAt : scratchpadAvailableAt) : max(scratchpadAvailableAt, srcAvailableAt);
			inst.y = i;
			p0[prefetch_data_count++] = inst;
			continue;
		}
		opcode -= RANDOMX_FREQ_IADD_M;

		if (opcode < RANDOMX_FREQ_ISUB_R)
		{
			registerLastChanged = (registerLastChanged & ~(0xFFul << (dst * 8))) | ((ulong)(i) << (dst * 8));
			registerWasChanged |= 1u << dst;
			continue;
		}
		opcode -= RANDOMX_FREQ_ISUB_R;

		if (opcode < RANDOMX_FREQ_ISUB_M)
		{
			registerLastChanged = (registerLastChanged & ~(0xFFul << (dst * 8))) | ((ulong)(i) << (dst * 8));
			registerWasChanged |= 1u << dst;
			inst.x = (src == dst) ? (((inst.y & ScratchpadL3Mask) >= 262144) ? scratchpadHighAvailableAt : scratchpadAvailableAt) : max(scratchpadAvailableAt, srcAvailableAt);
			inst.y = i;
			p0[prefetch_data_count++] = inst;
			continue;
		}
		opcode -= RANDOMX_FREQ_ISUB_M;

		if (opcode < RANDOMX_FREQ_IMUL_R)
		{
			registerLastChanged = (registerLastChanged & ~(0xFFul << (dst * 8))) | ((ulong)(i) << (dst * 8));
			registerWasChanged |= 1u << dst;
			continue;
		}
		opcode -= RANDOMX_FREQ_IMUL_R;

		if (opcode < RANDOMX_FREQ_IMUL_M)
		{
			registerLastChanged = (registerLastChanged & ~(0xFFul << (dst * 8))) | ((ulong)(i) << (dst * 8));
			registerWasChanged |= 1u << dst;
			inst.x = (src == dst) ? (((inst.y & ScratchpadL3Mask) >= 262144) ? scratchpadHighAvailableAt : scratchpadAvailableAt) : max(scratchpadAvailableAt, srcAvailableAt);
			inst.y = i;
			p0[prefetch_data_count++] = inst;
			continue;
		}
		opcode -= RANDOMX_FREQ_IMUL_M;

		if (opcode < RANDOMX_FREQ_IMULH_R)
		{
			registerLastChanged = (registerLastChanged & ~(0xFFul << (dst * 8))) | ((ulong)(i) << (dst * 8));
			registerWasChanged |= 1u << dst;
			continue;
		}
		opcode -= RANDOMX_FREQ_IMULH_R;

		if (opcode < RANDOMX_FREQ_IMULH_M)
		{
			registerLastChanged = (registerLastChanged & ~(0xFFul << (dst * 8))) | ((ulong)(i) << (dst * 8));
			registerWasChanged |= 1u << dst;
			inst.x = (src == dst) ? (((inst.y & ScratchpadL3Mask) >= 262144) ? scratchpadHighAvailableAt : scratchpadAvailableAt) : max(scratchpadAvailableAt, srcAvailableAt);
			inst.y = i;
			p0[prefetch_data_count++] = inst;
			continue;
		}
		opcode -= RANDOMX_FREQ_IMULH_M;

		if (opcode < RANDOMX_FREQ_ISMULH_R)
		{
			registerLastChanged = (registerLastChanged & ~(0xFFul << (dst * 8))) | ((ulong)(i) << (dst * 8));
			registerWasChanged |= 1u << dst;
			continue;
		}
		opcode -= RANDOMX_FREQ_ISMULH_R;

		if (opcode < RANDOMX_FREQ_ISMULH_M)
		{
			registerLastChanged = (registerLastChanged & ~(0xFFul << (dst * 8))) | ((ulong)(i) << (dst * 8));
			registerWasChanged |= 1u << dst;
			inst.x = (src == dst) ? (((inst.y & ScratchpadL3Mask) >= 262144) ? scratchpadHighAvailableAt : scratchpadAvailableAt) : max(scratchpadAvailableAt, srcAvailableAt);
			inst.y = i;
			p0[prefetch_data_count++] = inst;
			continue;
		}
		opcode -= RANDOMX_FREQ_ISMULH_M;

		if (opcode < RANDOMX_FREQ_IMUL_RCP)
		{
			if (inst.y & (inst.y - 1))
			{
				registerLastChanged = (registerLastChanged & ~(0xFFul << (dst * 8))) | ((ulong)(i) << (dst * 8));
				registerWasChanged |= 1u << dst;
			}
			continue;
		}
		opcode -= RANDOMX_FREQ_IMUL_RCP;

		if (opcode < RANDOMX_FREQ_INEG_R + RANDOMX_FREQ_IXOR_R)
		{
			registerLastChanged = (registerLastChanged & ~(0xFFul << (dst * 8))) | ((ulong)(i) << (dst * 8));
			registerWasChanged |= 1u << dst;
			continue;
		}
		opcode -= RANDOMX_FREQ_INEG_R + RANDOMX_FREQ_IXOR_R;

		if (opcode < RANDOMX_FREQ_IXOR_M)
		{
			registerLastChanged = (registerLastChanged & ~(0xFFul << (dst * 8))) | ((ulong)(i) << (dst * 8));
			registerWasChanged |= 1u << dst;
			inst.x = (src == dst) ? (((inst.y & ScratchpadL3Mask) >= 262144) ? scratchpadHighAvailableAt : scratchpadAvailableAt) : max(scratchpadAvailableAt, srcAvailableAt);
			inst.y = i;
			p0[prefetch_data_count++] = inst;
			continue;
		}
		opcode -= RANDOMX_FREQ_IXOR_M;

		if (opcode < RANDOMX_FREQ_IROR_R)
		{
			registerLastChanged = (registerLastChanged & ~(0xFFul << (dst * 8))) | ((ulong)(i) << (dst * 8));
			registerWasChanged |= 1u << dst;
			continue;
		}
		opcode -= RANDOMX_FREQ_IROR_R;

		if (opcode < RANDOMX_FREQ_ISWAP_R)
		{
			if (src != dst)
			{
				registerLastChanged = (registerLastChanged & ~(0xFFul << (dst * 8))) | ((ulong)(i) << (dst * 8));
				registerLastChanged = (registerLastChanged & ~(0xFFul << (src * 8))) | ((ulong)(i) << (src * 8));
				registerWasChanged |= (1u << dst) | (1u << src);
			}
			continue;
		}
		opcode -= RANDOMX_FREQ_ISWAP_R;

		if (opcode < RANDOMX_FREQ_ISTORE)
		{
			scratchpadAvailableAt = i + 1;
			if ((mod >> 4) >= 14)
				scratchpadHighAvailableAt = i + 1;

			// Mark ISTORE
			e[i].x = inst.x | (0x80 << 8);
			continue;
		}
		opcode -= RANDOMX_FREQ_ISTORE;
	}

	// Sort p0
	uint prev = p0[0].x;
	#pragma unroll(1)
	for (int j = 1; j < prefetch_data_count; ++j)
	{
		uint2 cur = p0[j];
		if (cur.x >= prev)
		{
			prev = cur.x;
			continue;
		}

		int j1 = j - 1;
		do {
			p0[j1 + 1] = p0[j1];
			--j1;
		} while ((j1 >= 0) && (p0[j1].x >= cur.x));
		p0[j1 + 1] = cur;
	}
	p0[prefetch_data_count].x = RANDOMX_PROGRAM_SIZE;

	__global int* prefecth_vgprs_stack = (__global int*)(p0 + prefetch_data_count + 1);

	enum { num_prefetch_vgprs = 16 };
	#pragma unroll
	for (int i = 0; i < num_prefetch_vgprs; ++i)
		prefecth_vgprs_stack[i] = NUM_VGPR_REGISTERS - 2 - i * 2;

	__global int* prefetched_vgprs = prefecth_vgprs_stack + num_prefetch_vgprs;

	#pragma unroll
	for (int i = 0; i < RANDOMX_PROGRAM_SIZE; ++i)
		prefetched_vgprs[i] = 0;

	int k = 0;
	uint2 prefetch_data = p0[0];
	int mem_counter = 0;
	int s_waitcnt_value = 100;
	int num_prefetch_vgprs_available = num_prefetch_vgprs;

	#pragma unroll(1)
	for (int i = 0; i < RANDOMX_PROGRAM_SIZE; ++i)
	{
		while ((prefetch_data.x == i) && (num_prefetch_vgprs_available > 0))
		{
			++mem_counter;
			const int vgpr_id = prefecth_vgprs_stack[--num_prefetch_vgprs_available];
			prefetched_vgprs[prefetch_data.y] = vgpr_id | (mem_counter << 16);

			p = jit_emit_instruction(p, e[prefetch_data.y], vgpr_id, mem_counter, lane_index, batch_size);
			s_waitcnt_value = 100;

			++k;
			prefetch_data = p0[k];
		}

		const int prefetched_vgprs_data = prefetched_vgprs[i];
		const int vgpr_id = prefetched_vgprs_data & 0xFFFF;
		const int prev_mem_counter = prefetched_vgprs_data >> 16;
		if (vgpr_id)
			prefecth_vgprs_stack[num_prefetch_vgprs_available++] = vgpr_id;

		if (e[i].x & (0x80 << 8))
		{
			++mem_counter;
			s_waitcnt_value = 100;
		}

		const int vmcnt = mem_counter - prev_mem_counter;
		p = jit_emit_instruction(p, e[i], -vgpr_id, (vmcnt < s_waitcnt_value) ? vmcnt : -1, lane_index, batch_size);
		if (vmcnt < s_waitcnt_value)
			s_waitcnt_value = vmcnt;
	}

	// Jump back to randomx_run kernel
	*(p++) = 0xbe801d0cu; // s_setpc_b64 s[12:13]

	return p;
}

__attribute__((reqd_work_group_size(64, 1, 1)))
__kernel void randomx_init(__global ulong* entropy, __global ulong* registers, __global uint2* intermediate_programs, __global uint* programs, uint batch_size)
{
	const uint global_index = get_global_id(0);
	if ((global_index % HASHES_PER_GROUP) == 0)
	{
		__global uint2* p0 = intermediate_programs + (global_index / HASHES_PER_GROUP) * (INTERMEDIATE_PROGRAM_SIZE / sizeof(uint2));
		__global uint* p = programs + (global_index / HASHES_PER_GROUP) * (COMPILED_PROGRAM_SIZE / sizeof(uint));
		__global uint2* e = (__global uint2*)(entropy + (global_index / HASHES_PER_GROUP) * HASHES_PER_GROUP * (ENTROPY_SIZE / sizeof(ulong)) + (128 / sizeof(ulong)));

		#pragma unroll(1)
		for (uint i = 0; i < HASHES_PER_GROUP; ++i, e += (ENTROPY_SIZE / sizeof(uint2)))
			p = generate_jit_code(e, p0, p, i, batch_size);
	}

	__global ulong* R = registers + global_index * 32;
	entropy += global_index * (ENTROPY_SIZE / sizeof(ulong));

	// Group R registers
	R[0] = 0;
	R[1] = 0;
	R[2] = 0;
	R[3] = 0;
	R[4] = 0;
	R[5] = 0;
	R[6] = 0;
	R[7] = 0;

	// Group A registers
	R[24] = getSmallPositiveFloatBits(entropy[0]);
	R[25] = getSmallPositiveFloatBits(entropy[1]);
	R[26] = getSmallPositiveFloatBits(entropy[2]);
	R[27] = getSmallPositiveFloatBits(entropy[3]);
	R[28] = getSmallPositiveFloatBits(entropy[4]);
	R[29] = getSmallPositiveFloatBits(entropy[5]);
	R[30] = getSmallPositiveFloatBits(entropy[6]);
	R[31] = getSmallPositiveFloatBits(entropy[7]);

	// ma, mx
	((__global uint*)(R + 16))[0] = entropy[8] & CacheLineAlignMask;
	((__global uint*)(R + 16))[1] = entropy[10];

	// address registers
	uint addressRegisters = entropy[12];
	((__global uint*)(R + 17))[0] = 0 + (addressRegisters & 1);
	addressRegisters >>= 1;
	((__global uint*)(R + 17))[1] = 2 + (addressRegisters & 1);
	addressRegisters >>= 1;
	((__global uint*)(R + 17))[2] = 4 + (addressRegisters & 1);
	addressRegisters >>= 1;
	((__global uint*)(R + 17))[3] = 6 + (addressRegisters & 1);

	// dataset offset
	((__global uint*)(R + 19))[0] = (entropy[13] & DatasetExtraItems) * CacheLineSize;

	// eMask
	R[20] = getFloatMask(entropy[14]);
	R[21] = getFloatMask(entropy[15]);
}
