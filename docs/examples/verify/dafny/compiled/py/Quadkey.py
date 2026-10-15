import sys
from typing import Callable, Any, TypeVar, NamedTuple
from math import floor
from itertools import count

import module_ as module_
import _dafny as _dafny
import System_ as System_

# Module: Quadkey

class default__:
    def  __init__(self):
        pass

    @staticmethod
    def Pow2(n):
        d_0___accumulator_ = 1
        while True:
            with _dafny.label():
                if (n) == (0):
                    return (1) * (d_0___accumulator_)
                elif True:
                    d_0___accumulator_ = (d_0___accumulator_) * (2)
                    in0_ = (n) - (1)
                    n = in0_
                    raise _dafny.TailCall()
                break

    @staticmethod
    def IsKey(k):
        def lambda0_(forall_var_0_):
            d_0_i_: int = forall_var_0_
            return not (((0) <= (d_0_i_)) and ((d_0_i_) < (len(k)))) or (((k)[d_0_i_]) in (_dafny.SeqWithoutIsStrInference(map(_dafny.CodePoint, "0123"))))

        return _dafny.quantifier(_dafny.IntegerRange(0, len(k)), True, lambda0_)

    @staticmethod
    def Digit(bitX, bitY):
        if ((bitX) == (0)) and ((bitY) == (0)):
            return _dafny.CodePoint('0')
        elif (bitY) == (0):
            return _dafny.CodePoint('1')
        elif (bitX) == (0):
            return _dafny.CodePoint('2')
        elif True:
            return _dafny.CodePoint('3')

    @staticmethod
    def Encode(x, y, zoom):
        d_0___accumulator_ = _dafny.SeqWithoutIsStrInference([])
        while True:
            with _dafny.label():
                if (zoom) == (0):
                    return (_dafny.SeqWithoutIsStrInference(map(_dafny.CodePoint, ""))) + (d_0___accumulator_)
                elif True:
                    d_0___accumulator_ = (_dafny.SeqWithoutIsStrInference([default__.Digit(_dafny.euclidian_modulus(x, 2), _dafny.euclidian_modulus(y, 2))])) + (d_0___accumulator_)
                    in0_ = _dafny.euclidian_division(x, 2)
                    in1_ = _dafny.euclidian_division(y, 2)
                    in2_ = (zoom) - (1)
                    x = in0_
                    y = in1_
                    zoom = in2_
                    raise _dafny.TailCall()
                break

    @staticmethod
    def Decode(k):
        if (len(k)) == (0):
            return (0, 0, 0)
        elif True:
            d_0_p_ = default__.Decode(_dafny.SeqWithoutIsStrInference((k)[:(len(k)) - (1):]))
            d_1_d_ = (k)[(len(k)) - (1)]
            d_2_dx_ = (1 if ((d_1_d_) == (_dafny.CodePoint('1'))) or ((d_1_d_) == (_dafny.CodePoint('3'))) else 0)
            d_3_dy_ = (1 if ((d_1_d_) == (_dafny.CodePoint('2'))) or ((d_1_d_) == (_dafny.CodePoint('3'))) else 0)
            return (((2) * ((d_0_p_)[0])) + (d_2_dx_), ((2) * ((d_0_p_)[1])) + (d_3_dy_), ((d_0_p_)[2]) + (1))

    @staticmethod
    def Parent(k):
        if (len(k)) == (0):
            return k
        elif True:
            return _dafny.SeqWithoutIsStrInference((k)[:(len(k)) - (1):])

    @staticmethod
    def EncodeChecked(x, y, zoom):
        k: _dafny.Seq = _dafny.SeqWithoutIsStrInference(map(_dafny.CodePoint, ""))
        k = default__.Encode(x, y, zoom)
        return k

