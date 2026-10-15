// Package Quadkey
// Dafny module Quadkey compiled into Go

package Quadkey

import (
	os "os"

	m__System "github.com/dafny-lang/DafnyRuntimeGo/v4/System_"
	_dafny "github.com/dafny-lang/DafnyRuntimeGo/v4/dafny"
)

var _ = os.Args
var _ _dafny.Dummy__
var _ m__System.Dummy__

type Dummy__ struct{}

// Definition of class Default__
type Default__ struct {
	dummy byte
}

func New_Default___() *Default__ {
	_this := Default__{}

	return &_this
}

type CompanionStruct_Default___ struct {
}

var Companion_Default___ = CompanionStruct_Default___{}

func (_this *Default__) Equals(other *Default__) bool {
	return _this == other
}

func (_this *Default__) EqualsGeneric(x interface{}) bool {
	other, ok := x.(*Default__)
	return ok && _this.Equals(other)
}

func (*Default__) String() string {
	return "Quadkey.Default__"
}
func (_this *Default__) ParentTraits_() []*_dafny.TraitID {
	return [](*_dafny.TraitID){}
}

var _ _dafny.TraitOffspring = &Default__{}

func (_static *CompanionStruct_Default___) Pow2(n _dafny.Int) _dafny.Int {
	var _0___accumulator _dafny.Int = _dafny.One
	_ = _0___accumulator
	goto TAIL_CALL_START
TAIL_CALL_START:
	if (n).Sign() == 0 {
		return (_dafny.One).Times(_0___accumulator)
	} else {
		_0___accumulator = (_0___accumulator).Times(_dafny.IntOfInt64(2))
		var _in0 _dafny.Int = (n).Minus(_dafny.One)
		_ = _in0
		n = _in0
		goto TAIL_CALL_START
	}
}
func (_static *CompanionStruct_Default___) IsKey(k _dafny.Sequence) bool {
	return _dafny.Quantifier(_dafny.IntegerRange(_dafny.Zero, _dafny.IntOfUint32((k).Cardinality())), true, func(_forall_var_0 _dafny.Int) bool {
		var _0_i _dafny.Int
		_0_i = interface{}(_forall_var_0).(_dafny.Int)
		return !(((_0_i).Sign() != -1) && ((_0_i).Cmp(_dafny.IntOfUint32((k).Cardinality())) < 0)) || (_dafny.Companion_Sequence_.Contains(_dafny.UnicodeSeqOfUtf8Bytes("0123"), (k).Select((_0_i).Uint32()).(_dafny.CodePoint)))
	})
}
func (_static *CompanionStruct_Default___) Digit(bitX _dafny.Int, bitY _dafny.Int) _dafny.CodePoint {
	if ((bitX).Sign() == 0) && ((bitY).Sign() == 0) {
		return _dafny.CodePoint('0')
	} else if (bitY).Sign() == 0 {
		return _dafny.CodePoint('1')
	} else if (bitX).Sign() == 0 {
		return _dafny.CodePoint('2')
	} else {
		return _dafny.CodePoint('3')
	}
}
func (_static *CompanionStruct_Default___) Encode(x _dafny.Int, y _dafny.Int, zoom _dafny.Int) _dafny.Sequence {
	var _0___accumulator _dafny.Sequence = _dafny.SeqOf()
	_ = _0___accumulator
	goto TAIL_CALL_START
TAIL_CALL_START:
	if (zoom).Sign() == 0 {
		return _dafny.Companion_Sequence_.Concatenate(_dafny.UnicodeSeqOfUtf8Bytes(""), _0___accumulator)
	} else {
		_0___accumulator = _dafny.Companion_Sequence_.Concatenate(_dafny.SeqOf(Companion_Default___.Digit((x).Modulo(_dafny.IntOfInt64(2)), (y).Modulo(_dafny.IntOfInt64(2)))), _0___accumulator)
		var _in0 _dafny.Int = (x).DivBy(_dafny.IntOfInt64(2))
		_ = _in0
		var _in1 _dafny.Int = (y).DivBy(_dafny.IntOfInt64(2))
		_ = _in1
		var _in2 _dafny.Int = (zoom).Minus(_dafny.One)
		_ = _in2
		x = _in0
		y = _in1
		zoom = _in2
		goto TAIL_CALL_START
	}
}
func (_static *CompanionStruct_Default___) Decode(k _dafny.Sequence) _dafny.Tuple {
	if (_dafny.IntOfUint32((k).Cardinality())).Sign() == 0 {
		return _dafny.TupleOf(_dafny.Zero, _dafny.Zero, _dafny.Zero)
	} else {
		var _0_p _dafny.Tuple = Companion_Default___.Decode((k).Take(((_dafny.IntOfUint32((k).Cardinality())).Minus(_dafny.One)).Uint32()))
		_ = _0_p
		var _1_d _dafny.CodePoint = (k).Select(((_dafny.IntOfUint32((k).Cardinality())).Minus(_dafny.One)).Uint32()).(_dafny.CodePoint)
		_ = _1_d
		var _2_dx _dafny.Int = (func() _dafny.Int {
			if ((_1_d) == (_dafny.CodePoint('1'))) || ((_1_d) == (_dafny.CodePoint('3'))) {
				return _dafny.One
			}
			return _dafny.Zero
		})()
		_ = _2_dx
		var _3_dy _dafny.Int = (func() _dafny.Int {
			if ((_1_d) == (_dafny.CodePoint('2'))) || ((_1_d) == (_dafny.CodePoint('3'))) {
				return _dafny.One
			}
			return _dafny.Zero
		})()
		_ = _3_dy
		return _dafny.TupleOf(((_dafny.IntOfInt64(2)).Times((*(_0_p).IndexInt(0)).(_dafny.Int))).Plus(_2_dx), ((_dafny.IntOfInt64(2)).Times((*(_0_p).IndexInt(1)).(_dafny.Int))).Plus(_3_dy), ((*(_0_p).IndexInt(2)).(_dafny.Int)).Plus(_dafny.One))
	}
}
func (_static *CompanionStruct_Default___) Parent(k _dafny.Sequence) _dafny.Sequence {
	if (_dafny.IntOfUint32((k).Cardinality())).Sign() == 0 {
		return k
	} else {
		return (k).Take(((_dafny.IntOfUint32((k).Cardinality())).Minus(_dafny.One)).Uint32())
	}
}
func (_static *CompanionStruct_Default___) EncodeChecked(x _dafny.Int, y _dafny.Int, zoom _dafny.Int) _dafny.Sequence {
	var k _dafny.Sequence = _dafny.EmptySeq
	_ = k
	k = Companion_Default___.Encode(x, y, zoom)
	return k
}

// End of class Default__
