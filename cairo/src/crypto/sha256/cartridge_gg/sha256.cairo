from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin
from starkware.cairo.common.math import assert_nn_le, unsigned_div_rem
from starkware.cairo.common.math_cmp import is_le
from starkware.cairo.common.memcpy import memcpy
from starkware.cairo.common.memset import memset
from starkware.cairo.common.pow import pow

from crypto.sha256.cartridge_gg.packed_sha256 import BLOCK_SIZE, compute_message_schedule, sha2_compress, get_round_constants

const SHA256_INPUT_CHUNK_SIZE_FELTS = 16
const SHA256_INPUT_CHUNK_SIZE_BYTES = 64
const SHA256_STATE_SIZE_FELTS = 8
# Each instance consists of 16 words of message, 8 words for the input state and 8 words
# for the output state.
const SHA256_INSTANCE_SIZE = SHA256_INPUT_CHUNK_SIZE_FELTS + 2 * SHA256_STATE_SIZE_FELTS

# Computes SHA256 of 'input'. Inputs of arbitrary length are supported.
# To use this function, split the input into (up to) 14 words of 32 bits (big endian).
# For example, to compute sha256('Hello world'), use:
#   input = [1214606444, 1864398703, 1919706112]
# where:
#   1214606444 == int.from_bytes(b'Hell', 'big')
#   1864398703 == int.from_bytes(b'o wo', 'big')
#   1919706112 == int.from_bytes(b'rld\x00', 'big')  # Note the '\x00' padding.
#
# output is an array of 8 32-bit words (big endian).
#
# Note: You must call finalize_sha2() at the end of the program. Otherwise, this function
# is not sound and a malicious prover may return a wrong result.
# Note: the interface of this function may change in the future.
func compute_sha256{range_check_ptr, sha256_ptr: felt*}(data: felt*, n_bytes: felt) -> (
    output : felt*
):
    alloc_locals

    # Block layout:
    #  0 - 16: Working variables
    # 26 - 24: Input chunk
    # 24 - 32: Output

    # Set the initial state to IV.
    assert sha256_ptr[0] = 0x6A09E667
    assert sha256_ptr[1] = 0xBB67AE85
    assert sha256_ptr[2] = 0x3C6EF372
    assert sha256_ptr[3] = 0xA54FF53A
    assert sha256_ptr[4] = 0x510E527F
    assert sha256_ptr[5] = 0x9B05688C
    assert sha256_ptr[6] = 0x1F83D9AB
    assert sha256_ptr[7] = 0x5BE0CD19

    sha256_inner(data=data, n_bytes=n_bytes, total_bytes=n_bytes)

    let output = sha256_ptr
    let sha256_ptr = sha256_ptr + SHA256_STATE_SIZE_FELTS
    return (output)
end

func _sha256_chunk{range_check_ptr, sha256_start: felt*, state: felt*, output: felt*}():
    %{
        from starkware.cairo.common.cairo_sha256.sha256_utils import (
            compute_message_schedule, sha2_compress_function)

        _sha256_input_chunk_size_felts = int(ids.SHA256_INPUT_CHUNK_SIZE_FELTS)
        assert 0 <= _sha256_input_chunk_size_felts < 100
        w = compute_message_schedule(memory.get_range(
            ids.sha256_start, _sha256_input_chunk_size_felts))
        new_state = sha2_compress_function(memory.get_range(ids.state, int(ids.SHA256_STATE_SIZE_FELTS)), w)
        segments.write_arg(ids.output, new_state)
    %}
    return ()
end

# Inner loop for sha256. sha256_ptr points to the middle of an instance: after the initial state,
# before the message.
func sha256_inner{range_check_ptr, sha256_ptr: felt*}(
    data: felt*, n_bytes: felt, total_bytes: felt
):
    alloc_locals

    let state = sha256_ptr
    let sha256_ptr = sha256_ptr + SHA256_STATE_SIZE_FELTS
    let sha256_start = sha256_ptr

    let (zero_bytes) = is_le(n_bytes, 0)
    let (zero_total_bytes) = is_le(total_bytes, 0)

    # If the previous message block was full we are still missing "1" at the end of the message
    let (_, r_div_by_64) = unsigned_div_rem(total_bytes, 64)
    let (missing_bit_one) = is_le(r_div_by_64, 0)

    # This works for 0 total bytes too, because zero_chunk will be -1 and, therefore, not 0.
    let zero_chunk = zero_bytes - zero_total_bytes - missing_bit_one

    let (is_last_block) = is_le(n_bytes, 55)
    if is_last_block != 0:
        _sha256_input(data, n_bytes, SHA256_INPUT_CHUNK_SIZE_FELTS - 2, zero_chunk)
        assert sha256_ptr[0] = 0
        assert sha256_ptr[1] = total_bytes * 8
        let sha256_ptr = sha256_ptr + 2
        _sha256_chunk{sha256_start=sha256_start, state=state, output=sha256_ptr}()

        return ()
    end

    let (q, r) = unsigned_div_rem(n_bytes, SHA256_INPUT_CHUNK_SIZE_BYTES)
    let (is_remainder_block) = is_le(q, 0)
    if is_remainder_block == 1:
        _sha256_input(data, r, SHA256_INPUT_CHUNK_SIZE_FELTS, 0)
        _sha256_chunk{sha256_start=sha256_start, state=state, output=sha256_ptr}()

        memcpy(sha256_ptr + SHA256_STATE_SIZE_FELTS, sha256_ptr, SHA256_STATE_SIZE_FELTS)
        let sha256_ptr = sha256_ptr + SHA256_STATE_SIZE_FELTS

        return sha256_inner(
            data=data,
            n_bytes=n_bytes - r,
            total_bytes=total_bytes,
        )
    else:
        _sha256_input(data, SHA256_INPUT_CHUNK_SIZE_BYTES, SHA256_INPUT_CHUNK_SIZE_FELTS, 0)
        _sha256_chunk{sha256_start=sha256_start, state=state, output=sha256_ptr}()

        memcpy(sha256_ptr + SHA256_STATE_SIZE_FELTS, sha256_ptr, SHA256_STATE_SIZE_FELTS)
        let sha256_ptr = sha256_ptr + SHA256_STATE_SIZE_FELTS

        return sha256_inner(
            data=data + SHA256_INPUT_CHUNK_SIZE_FELTS,
            n_bytes=n_bytes - SHA256_INPUT_CHUNK_SIZE_BYTES,
            total_bytes=total_bytes,
        )
    end
end

func _sha256_input{range_check_ptr, sha256_ptr: felt*}(
    input: felt*, n_bytes: felt, n_words: felt, pad_chunk: felt):
    alloc_locals

    local full_word
    %{ ids.full_word = int(ids.n_bytes >= 4) %}

    if full_word != 0:
        assert sha256_ptr[0] = input[0]
        let sha256_ptr = sha256_ptr + 1
        return _sha256_input(input=input + 1, n_bytes=n_bytes - 4, n_words=n_words - 1, pad_chunk=pad_chunk)
    end

    if n_words == 0:
        return ()
    end

    if n_bytes == 0 and pad_chunk == 1:
        memset(dst=sha256_ptr, value=0, n=n_words)
        let sha256_ptr = sha256_ptr + n_words
        return ()
    end 

    if n_bytes == 0:
        # This is the last input word, so we should add a byte '0x80' at the end and fill the rest with
        # zeros.
        assert sha256_ptr[0] = 0x80000000
        memset(dst=sha256_ptr + 1, value=0, n=n_words - 1)
        let sha256_ptr = sha256_ptr + n_words
        return ()
    end

   
    assert_nn_le(n_bytes, 3)
    let (padding) = pow(256, 3 - n_bytes)
    local range_check_ptr = range_check_ptr

    assert sha256_ptr[0] = input[0] + padding * 0x80

    memset(dst=sha256_ptr + 1, value=0, n=n_words - 1)
    let sha256_ptr = sha256_ptr + n_words
    return ()
end

# Handles n blocks of BLOCK_SIZE SHA256 instances.
func _finalize_sha256_inner{range_check_ptr, bitwise_ptr : BitwiseBuiltin*}(
        sha256_ptr : felt*, n : felt, round_constants : felt*):
    if n == 0:
        return ()
    end

    alloc_locals

    local MAX_VALUE = 2 ** 32 - 1

    let sha256_start = sha256_ptr

    let (local message_start : felt*) = alloc()
    let (local input_state_start : felt*) = alloc()

    # Handle input state.

    tempvar input_state = input_state_start
    tempvar sha256_ptr = sha256_ptr
    tempvar range_check_ptr = range_check_ptr
    tempvar m = SHA256_STATE_SIZE_FELTS

    input_state_loop:
    tempvar x0 = sha256_ptr[0 * SHA256_INSTANCE_SIZE]
    assert [range_check_ptr + 0] = x0
    assert [range_check_ptr + 1] = MAX_VALUE - x0
    tempvar x1 = sha256_ptr[1 * SHA256_INSTANCE_SIZE]
    assert [range_check_ptr + 2] = x1
    assert [range_check_ptr + 3] = MAX_VALUE - x1
    tempvar x2 = sha256_ptr[2 * SHA256_INSTANCE_SIZE]
    assert [range_check_ptr + 4] = x2
    assert [range_check_ptr + 5] = MAX_VALUE - x2
    tempvar x3 = sha256_ptr[3 * SHA256_INSTANCE_SIZE]
    assert [range_check_ptr + 6] = x3
    assert [range_check_ptr + 7] = MAX_VALUE - x3
    tempvar x4 = sha256_ptr[4 * SHA256_INSTANCE_SIZE]
    assert [range_check_ptr + 8] = x4
    assert [range_check_ptr + 9] = MAX_VALUE - x4
    tempvar x5 = sha256_ptr[5 * SHA256_INSTANCE_SIZE]
    assert [range_check_ptr + 10] = x5
    assert [range_check_ptr + 11] = MAX_VALUE - x5
    tempvar x6 = sha256_ptr[6 * SHA256_INSTANCE_SIZE]
    assert [range_check_ptr + 12] = x6
    assert [range_check_ptr + 13] = MAX_VALUE - x6
    assert input_state[0] = x0 + 2 ** 35 * x1 + 2 ** (35 * 2) * x2 + 2 ** (35 * 3) * x3 +
        2 ** (35 * 4) * x4 + 2 ** (35 * 5) * x5 + 2 ** (35 * 6) * x6

    tempvar input_state = input_state + 1
    tempvar sha256_ptr = sha256_ptr + 1
    tempvar range_check_ptr = range_check_ptr + 14
    tempvar m = m - 1
    jmp input_state_loop if m != 0

    # Handle message.

    tempvar message = message_start
    tempvar sha256_ptr = sha256_ptr
    tempvar range_check_ptr = range_check_ptr
    tempvar m = SHA256_INPUT_CHUNK_SIZE_FELTS

    message_loop:
    tempvar x0 = sha256_ptr[0 * SHA256_INSTANCE_SIZE]
    assert [range_check_ptr + 0] = x0
    assert [range_check_ptr + 1] = MAX_VALUE - x0
    tempvar x1 = sha256_ptr[1 * SHA256_INSTANCE_SIZE]
    assert [range_check_ptr + 2] = x1
    assert [range_check_ptr + 3] = MAX_VALUE - x1
    tempvar x2 = sha256_ptr[2 * SHA256_INSTANCE_SIZE]
    assert [range_check_ptr + 4] = x2
    assert [range_check_ptr + 5] = MAX_VALUE - x2
    tempvar x3 = sha256_ptr[3 * SHA256_INSTANCE_SIZE]
    assert [range_check_ptr + 6] = x3
    assert [range_check_ptr + 7] = MAX_VALUE - x3
    tempvar x4 = sha256_ptr[4 * SHA256_INSTANCE_SIZE]
    assert [range_check_ptr + 8] = x4
    assert [range_check_ptr + 9] = MAX_VALUE - x4
    tempvar x5 = sha256_ptr[5 * SHA256_INSTANCE_SIZE]
    assert [range_check_ptr + 10] = x5
    assert [range_check_ptr + 11] = MAX_VALUE - x5
    tempvar x6 = sha256_ptr[6 * SHA256_INSTANCE_SIZE]
    assert [range_check_ptr + 12] = x6
    assert [range_check_ptr + 13] = MAX_VALUE - x6
    assert message[0] = x0 + 2 ** 35 * x1 + 2 ** (35 * 2) * x2 + 2 ** (35 * 3) * x3 +
        2 ** (35 * 4) * x4 + 2 ** (35 * 5) * x5 + 2 ** (35 * 6) * x6

    tempvar message = message + 1
    tempvar sha256_ptr = sha256_ptr + 1
    tempvar range_check_ptr = range_check_ptr + 14
    tempvar m = m - 1
    jmp message_loop if m != 0

    # Run sha256 on the 7 instances.

    local sha256_ptr : felt* = sha256_ptr
    local range_check_ptr = range_check_ptr
    compute_message_schedule(message_start)
    let (outputs) = sha2_compress(input_state_start, message_start, round_constants)
    local bitwise_ptr : BitwiseBuiltin* = bitwise_ptr

    # Handle outputs.

    tempvar outputs = outputs
    tempvar sha256_ptr = sha256_ptr
    tempvar range_check_ptr = range_check_ptr
    tempvar m = SHA256_STATE_SIZE_FELTS

    output_loop:
    tempvar x0 = sha256_ptr[0 * SHA256_INSTANCE_SIZE]
    assert [range_check_ptr] = x0
    assert [range_check_ptr + 1] = MAX_VALUE - x0
    tempvar x1 = sha256_ptr[1 * SHA256_INSTANCE_SIZE]
    assert [range_check_ptr + 2] = x1
    assert [range_check_ptr + 3] = MAX_VALUE - x1
    tempvar x2 = sha256_ptr[2 * SHA256_INSTANCE_SIZE]
    assert [range_check_ptr + 4] = x2
    assert [range_check_ptr + 5] = MAX_VALUE - x2
    tempvar x3 = sha256_ptr[3 * SHA256_INSTANCE_SIZE]
    assert [range_check_ptr + 6] = x3
    assert [range_check_ptr + 7] = MAX_VALUE - x3
    tempvar x4 = sha256_ptr[4 * SHA256_INSTANCE_SIZE]
    assert [range_check_ptr + 8] = x4
    assert [range_check_ptr + 9] = MAX_VALUE - x4
    tempvar x5 = sha256_ptr[5 * SHA256_INSTANCE_SIZE]
    assert [range_check_ptr + 10] = x5
    assert [range_check_ptr + 11] = MAX_VALUE - x5
    tempvar x6 = sha256_ptr[6 * SHA256_INSTANCE_SIZE]
    assert [range_check_ptr + 12] = x6
    assert [range_check_ptr + 13] = MAX_VALUE - x6

    assert outputs[0] = x0 + 2 ** 35 * x1 + 2 ** (35 * 2) * x2 + 2 ** (35 * 3) * x3 +
        2 ** (35 * 4) * x4 + 2 ** (35 * 5) * x5 + 2 ** (35 * 6) * x6

    tempvar outputs = outputs + 1
    tempvar sha256_ptr = sha256_ptr + 1
    tempvar range_check_ptr = range_check_ptr + 14
    tempvar m = m - 1
    jmp output_loop if m != 0

    return _finalize_sha256_inner(
        sha256_ptr=sha256_start + SHA256_INSTANCE_SIZE * BLOCK_SIZE,
        n=n - 1,
        round_constants=round_constants)
end

# Verifies that the results of sha256() are valid.
func finalize_sha256{range_check_ptr, bitwise_ptr : BitwiseBuiltin*}(
        sha256_ptr_start : felt*, sha256_ptr_end : felt*):
    alloc_locals

    let (__fp__, _) = get_fp_and_pc()

    let (round_constants) = get_round_constants()

    # We reuse the output state of the previous chunk as input to the next.
    tempvar n = (sha256_ptr_end - sha256_ptr_start) / SHA256_INSTANCE_SIZE
    if n == 0:
        return ()
    end

    %{
        # Add dummy pairs of input and output.
        from starkware.cairo.common.cairo_sha256.sha256_utils import (
            IV, compute_message_schedule, sha2_compress_function)

        _block_size = int(ids.BLOCK_SIZE)
        assert 0 <= _block_size < 20
        _sha256_input_chunk_size_felts = int(ids.SHA256_INPUT_CHUNK_SIZE_FELTS)
        assert 0 <= _sha256_input_chunk_size_felts < 100

        message = [0] * _sha256_input_chunk_size_felts
        w = compute_message_schedule(message)
        output = sha2_compress_function(IV, w)
        padding = (IV + message + output) * (_block_size - ids.n)
        segments.write_arg(ids.sha256_ptr_end, padding)
    %}

    # Compute the amount of blocks (rounded up).
    let (local q, r) = unsigned_div_rem(n + BLOCK_SIZE - 1, BLOCK_SIZE)
    _finalize_sha256_inner(sha256_ptr_start, n=q, round_constants=round_constants)
    return ()
end
