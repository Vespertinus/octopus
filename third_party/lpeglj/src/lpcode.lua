--[[
LPEGLJ
lpcode.lua
Generating code from tree
Copyright (C) 2013 Rostislav Sacek.
based on LPeg v0.12 - PEG pattern matching for Lua
Lua.org & PUC-Rio  written by Roberto Ierusalimschy
http://www.inf.puc-rio.br/~roberto/lpeg/

** Permission is hereby granted, free of charge, to any person obtaining
** a copy of this software and associated documentation files (the
** "Software"), to deal in the Software without restriction, including
** without limitation the rights to use, copy, modify, merge, publish,
** distribute, sublicense, and/or sell copies of the Software, and to
** permit persons to whom the Software is furnished to do so, subject to
** the following conditions:
**
** The above copyright notice and this permission notice shall be
** included in all copies or substantial portions of the Software.
**
** THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
** EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
** MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
** IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
** CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
** TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
** SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
**
** [ MIT license: http://www.opensource.org/licenses/mit-license.php ]
--]]

local ffi = require"ffi"

local band, bor, bnot, rshift, lshift = bit.band, bit.bor, bit.bnot, bit.rshift, bit.lshift

local TChar = 0
local TSet = 1
local TAny = 2 -- standard PEG elements
local TTrue = 3
local TFalse = 4
local TRep = 5
local TSeq = 6
local TChoice = 7
local TNot = 8
local TAnd = 9
local TCall = 10
local TOpenCall = 11
local TRule = 12 -- sib1 is rule's pattern, sib2 is 'next' rule
local TGrammar = 13 -- sib1 is initial (and first) rule
local TBehind = 14 -- match behind
local TCapture = 15 -- regular capture
local TRunTime = 16 -- run-time capture


local IAny = 0 -- if no char, fail
local IChar = 1 -- if char != val, fail
local ISet = 2 -- if char not in val, fail
local ITestAny = 3 -- in no char, jump to 'offset'
local ITestChar = 4 -- if char != val, jump to 'offset'
local ITestSet = 5 -- if char not in val, jump to 'offset'
local ISpan = 6 -- read a span of chars in val
local IBehind = 7 -- walk back 'val' characters (fail if not possible)
local IRet = 8 -- return from a rule
local IEnd = 9 -- end of pattern
local IChoice = 10 -- stack a choice; next fail will jump to 'offset'
local IJmp = 11 -- jump to 'offset'
local ICall = 12 -- call rule at 'offset'
local IOpenCall = 13 -- call rule number 'offset' (must be closed to a ICall)
local ICommit = 14 -- pop choice and jump to 'offset'
local IPartialCommit = 15 -- update top choice to current position and jump
local IBackCommit = 16 -- "fails" but jump to its own 'offset'
local IFailTwice = 17 -- pop one choice and then fail
local IFail = 18 -- go back to saved state on choice and jump to saved offset
local IGiveup = 19 -- internal use
local IFullCapture = 20 -- complete capture of last 'off' chars
local IOpenCapture = 21 -- start a capture
local ICloseCapture = 22
local ICloseRunTime = 23


local Cclose = 0
local Cposition = 1
local Cconst = 2
local Cbackref = 3
local Carg = 4
local Csimple = 5
local Ctable = 6
local Cfunction = 7
local Cquery = 8
local Cstring = 9
local Cnum = 10
local Csubst = 11
local Cfold = 12
local Cruntime = 13
local Cgroup = 14


local PEnullable = 0
local PEnofail = 1
local NOINST = -1


local MAXBEHIND = 255
local MAXRULES = 200
local MAXOFF = 0xF

local numsiblings = {
    0, 0, 0, -- char, set, any
    0, 0, -- true, false
    1, -- rep
    2, 2, -- seq, choice
    1, 1, -- not, and
    0, 0, 2, 1, -- call, opencall, rule, grammar
    1, -- behind
    1, 1 -- capture, runtime capture
}


local fullset = ffi.new('uint32_t[8]', { 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, })

-- {======================================================
-- Analysis and some optimizations
-- =======================================================

local function codegen(code, tree, fl, opt, tt, index) end


-- Check whether a charset is empty (IFail), singleton (IChar),
-- full (IAny), or none of those (ISet).

local function charsettype(cs)
    local count = 0;
    local candidate = -1; -- candidate position for a char
    for i = 0, 8 - 1 do
        local b = cs[i];
        if b == 0 then
            if count > 1 then
                return ISet; -- else set is still empty
            end
        elseif b == 0xFFFFFFFF then
            if count < (i * 32) then
                return ISet;
            else
                count = count + 32; -- set is still full
            end
        elseif band(b, (b - 1)) == 0 then -- byte has only one bit?
            if count > 0 then
                return ISet; -- set is neither full nor empty
            else -- set has only one char till now; track it
                count = count + 1;
                candidate = i;
            end
        else
            return ISet; -- byte is neither empty, full, nor singleton
        end
    end
    if count == 0 then
        return IFail, 0 -- empty set
    elseif count == 1 then -- singleton; find character bit inside byte
        local b = cs[candidate];
        local c = candidate * 32;
        for i = 1, 32 do
            if b == 1 then
                c = c + i - 1
                break
            end
            b = rshift(b, 1)
        end
        return IChar, string.char(c)
    elseif count == 256 then
        return IAny, 0 -- full set
    else
        assert(false) -- should have returned by now
    end
end


-- A few basic operations on Charsets

local function cs_complement(cs)
    for i = 0, 8 - 1 do
        cs[i] = bnot(cs[i])
    end
end


local function cs_equal(cs1, cs2)
    for i = 0, 8 - 1 do
        if cs1[i] ~= cs2[i] then
            return
        end
    end
    return true
end


-- computes whether sets st1 and st2 are disjoint

local function cs_disjoint(st1, st2)
    for i = 0, 8 - 1 do
        if band(st1[i], st2[i]) ~= 0 then
            return
        end
    end
    return true
end


-- Convert a 'char' pattern (TSet, TChar, TAny) to a charset

local function tocharset(tree, index)
    local val = ffi.new('uint32_t[8]')
    if tree[index].tag == TSet then
        ffi.copy(val, tree[index].val, 32)
        return val
    elseif tree[index].tag == TChar then
        local b = tree[index].val:byte()
        -- only one char
        -- add that one
        val[rshift(b, 5)] = lshift(1, band(b, 31))
        return val
    elseif tree[index].tag == TAny then
        ffi.fill(val, 32, 0xff)
        return val
    end
end


-- checks whether a pattern has captures

local function hascaptures(tree, index)
    if tree[index].tag == TCapture or tree[index].tag == TRunTime then
        return true
    else
        local ns = numsiblings[tree[index].tag + 1]
        if ns == 0 then
            return
        elseif ns == 1 then
            return hascaptures(tree, index + 1)
        elseif ns == 2 then
            if hascaptures(tree, index + 1) then
                return true
            else
                return hascaptures(tree, index + tree[index].ps)
            end
        else
            assert(false)
        end
    end
end


-- Checks how a pattern behaves regarding the empty string,
-- in one of two different ways:
-- A pattern is *nullable* if it can match without consuming any character;
-- A pattern is *nofail* if it never fails for any string
-- (including the empty string).
-- The difference is only for predicates; for patterns without
-- predicates, the two properties are equivalent.
-- (With predicates, &'a' is nullable but not nofail. Of course,
-- nofail => nullable.)
-- These functions are all convervative in the following way:
-- p is nullable => nullable(p)
-- nofail(p) => p cannot fail
-- (The function assumes that TOpenCall and TRunTime are not nullable:
-- TOpenCall must be checked again when the grammar is fixed;
-- TRunTime is an arbitrary choice.)

local function checkaux(tree, pred, index)
    local tag = tree[index].tag
    if tag == TChar or tag == TSet or tag == TAny or
            tag == TFalse or tag == TOpenCall then
        return -- not nullable
    elseif tag == TRep or tag == TTrue then
        return true -- no fail
    elseif tag == TNot or tag == TBehind then
        -- can match empty, but may fail
        if pred == PEnofail then
            return
        else
            return true -- PEnullable
        end
    elseif tag == TAnd then
        -- can match empty; fail iff body does
        if pred == PEnullable then
            return true
        else
            return checkaux(tree, pred, index + 1)
        end
    elseif tag == TRunTime then -- can fail; match empty iff body does
        if pred == PEnofail then
            return
        else
            return checkaux(tree, pred, index + 1)
        end
    elseif tag == TSeq then
        if not checkaux(tree, pred, index + 1) then
            return
        else
            return checkaux(tree, pred, index + tree[index].ps)
        end
    elseif tag == TChoice then
        if checkaux(tree, pred, index + tree[index].ps) then
            return true
        else
            return checkaux(tree, pred, index + 1)
        end
    elseif tag == TCapture or tag == TGrammar or tag == TRule then
        return checkaux(tree, pred, index + 1)
    elseif tag == TCall then
        return checkaux(tree, pred, index + tree[index].ps)
    else
        assert(false)
    end
end


-- number of characters to match a pattern (or -1 if variable)
-- ('count' avoids infinite loops for grammars)

local function fixedlenx(tree, count, len, index)
    local tag = tree[index].tag
    if tag == TChar or tag == TSet or tag == TAny then
        return len + 1;
    elseif tag == TFalse or tag == TTrue or tag == TNot or tag == TAnd or tag == TBehind then
        return len;
    elseif tag == TRep or tag == TRunTime or tag == TOpenCall then
        return -1;
    elseif tag == TCapture or tag == TRule or tag == TGrammar then
        return fixedlenx(tree, count, len, index + 1)
    elseif tag == TCall then
        if count >= MAXRULES then
            return -1; -- may be a loop
        else
            return fixedlenx(tree, count + 1, len, index + tree[index].ps)
        end
    elseif tag == TSeq then
        len = fixedlenx(tree, count, len, index + 1)
        if (len < 0) then
            return -1;
        else
            return fixedlenx(tree, count, len, index + tree[index].ps)
        end
    elseif tag == TChoice then
        local n1 = fixedlenx(tree, count, len, index + 1)
        if n1 < 0 then return -1 end
        local n2 = fixedlenx(tree, count, len, index + tree[index].ps)
        if n1 == n2 then
            return n1
        else
            return -1
        end
    else
        assert(false)
    end
end


-- Computes the 'first set' of a pattern.
-- The result is a conservative aproximation:
--   match p ax -> x' for some x ==> a in first(p).
--   match p '' -> ''            ==> returns 1.
-- The set 'follow' is the first set of what follows the
-- pattern (full set if nothing follows it)

local function getfirst(tree, follow, index)
    local tag = tree[index].tag
    if tag == TChar or tag == TSet or tag == TAny then
        local firstset = tocharset(tree, index)
        return 0, firstset
    elseif tag == TTrue then
        local firstset = ffi.new('uint32_t[8]')
        for i = 0, 8 - 1 do
            firstset[i] = follow[i]
        end
        return 1, firstset
    elseif tag == TFalse then
        local firstset = ffi.new('uint32_t[8]')
        for i = 0, 8 - 1 do
            firstset[i] = 0
        end
        return 0, firstset
    elseif tag == TChoice then
        local e1, firstset = getfirst(tree, follow, index + 1)
        local e2, csaux = getfirst(tree, follow, index + tree[index].ps)
        for i = 0, 8 - 1 do
            firstset[i] = bor(firstset[i], csaux[i])
        end
        return bor(e1, e2), firstset
    elseif tag == TSeq then
        if not checkaux(tree, PEnullable, index + 1) then
            return getfirst(tree, fullset, index + 1)
        else -- FIRST(p1 p2, fl) = FIRST(p1, FIRST(p2, fl))
            local e2, csaux = getfirst(tree, follow, index + tree[index].ps)
            local e1, firstset = getfirst(tree, csaux, index + 1)
            if e1 == 0 then -- 'e1' ensures that first can be used
                return 0, firstset
            elseif band(bor(e1, e2), 2) == 2 then -- one of the children has a matchtime?
                return 2, firstset -- pattern has a matchtime capture
            else
                return e2, firstset -- else depends on 'e2'
            end
        end
    elseif tag == TRep then
        local _, firstset = getfirst(tree, follow, index + 1)
        for i = 0, 8 - 1 do
            firstset[i] = bor(firstset[i], follow[i])
        end
        return 1, firstset -- accept the empty string
    elseif tag == TCapture or tag == TGrammar or tag == TRule then
        return getfirst(tree, follow, index + 1)
    elseif tag == TRunTime then -- function invalidates any follow info.
        local e, firstset = getfirst(tree, fullset, index + 1)
        if e ~= 0 then
            return 2, firstset -- function is not "protected"?
        else
            return 0, firstset -- pattern inside capture ensures first can be used
        end
    elseif tag == TCall then
        return getfirst(tree, follow, index + tree[index].ps)
    elseif tag == TAnd then
        local e, firstset = getfirst(tree, follow, index + 1)
        for i = 0, 8 - 1 do
            firstset[i] = band(firstset[i], follow[i])
        end
        return e, firstset
    elseif tag == TNot then
        local firstset = tocharset(tree, index + 1)
        if firstset then
            cs_complement(firstset)
            return 1, firstset
        end
        local e, firstset = getfirst(tree, follow, index + 1)
        for i = 0, 8 - 1 do
            firstset[i] = follow[i] -- uses follow
        end
        return bor(e, 1), firstset -- always can accept the empty string
    elseif tag == TBehind then -- instruction gives no new information
        -- call 'getfirst' to check for math-time captures
        local e, firstset = getfirst(tree, follow, index + 1)
        for i = 0, 8 - 1 do
            firstset[i] = follow[i] -- uses follow
        end
        return bor(e, 1), firstset -- always can accept the empty string
    else
        assert(false)
    end
end


-- If it returns true, then pattern can fail only depending on the next
-- character of the subject

local function headfail(tree, index)
    local tag = tree[index].tag
    if tag == TChar or tag == TSet or tag == TAny or tag == TFalse then
        return true
    elseif tag == TTrue or tag == TRep or tag == TRunTime or tag == TNot or tag == TBehind then
        return
    elseif tag == TCapture or tag == TGrammar or tag == TRule or tag == TAnd then
        return headfail(tree, index + 1)
    elseif tag == TCall then
        return headfail(tree, index + tree[index].ps)
    elseif tag == TSeq then
        if not checkaux(tree, PEnofail, index + tree[index].ps) then
            return
        else
            return headfail(tree, index + 1)
        end
    elseif tag == TChoice then
        if not headfail(tree, index + 1) then
            return
        else
            return headfail(tree, index + tree[index].ps)
        end
    else
        assert(false)
    end
end


-- Check whether the code generation for the given tree can benefit
-- from a follow set (to avoid computing the follow set when it is
-- not needed)

local function needfollow(tree, index)
    local tag = tree[index].tag
    if tag == TChar or tag == TSet or tag == TAny or tag == TFalse or tag == TTrue or tag == TAnd or tag == TNot or
            tag == TRunTime or tag == TGrammar or tag == TCall or tag == TBehind then
        return
    elseif tag == TChoice or tag == TRep then
        return true
    elseif tag == TCapture then
        return needfollow(tree, index + 1)
    elseif tag == TSeq then
        return needfollow(tree, index + tree[index].ps)
    else
        assert(false)
    end
end

-- ======================================================


-- {======================================================
-- Code generation
-- =======================================================


-- code generation is recursive; 'opt' indicates that the code is
-- being generated under a 'IChoice' operator jumping to its end.
-- 'tt' points to a previous test protecting this code. 'fl' is
-- the follow set of the pattern.


local function addinstruction(code, op, val)
    local inst = {}
    code[#code + 1] = inst
    inst.code = op;
    inst.val = val
    return #code
end


local function setoffset(code, instruction, offset)
    code[instruction].offset = offset;
end


-- Add a capture instruction:
-- 'op' is the capture instruction; 'cap' the capture kind;
-- 'key' the key into ktable; 'aux' is optional offset

local function addinstcap(code, op, cap, key, aux)
    local i = addinstruction(code, op, bor(cap, lshift(aux, 4)))
    setoffset(code, i, key)
    return i
end


local function jumptothere(code, instruction, target)
    if instruction >= 0 then
        setoffset(code, instruction, target - instruction)
    end
end


local function jumptohere(code, instruction)
    jumptothere(code, instruction, #code + 1)
end


-- Code an IChar instruction, or IAny if there is an equivalent
-- test dominating it

local function codechar(code, c, tt)
    assert(tt ~= 0)
    if tt > 0 and code[tt].code == ITestChar and
            code[tt].val == c then
        addinstruction(code, IAny, 0)
    else
        addinstruction(code, IChar, c)
    end
end


-- Code an ISet instruction

local function coderealcharset(code, cs)
    return addinstruction(code, ISet, cs)
end


-- code a char set, optimizing unit sets for IChar, "complete"
-- sets for IAny, and empty sets for IFail; also use an IAny
-- when instruction is dominated by an equivalent test.

local function codecharset(code, cs, tt)
    local op, c = charsettype(cs)
    if op == IChar then
        codechar(code, c, tt)
    elseif op == ISet then
        assert(tt ~= 0)
        if tt > 0 and code[tt].code == ITestSet and
                cs_equal(cs, code[tt].val) then
            addinstruction(code, IAny, 0)
        else
            coderealcharset(code, cs)
        end
    else
        addinstruction(code, op, c)
    end
end


-- code a test set, optimizing unit sets for ITestChar, "complete"
-- sets for ITestAny, and empty sets for IJmp (always fails).
-- 'e' is true iff test should accept the empty string. (Test
-- instructions in the current VM never accept the empty string.)

local function codetestset(code, cs, e)
    if e ~= 0 then
        return NOINST -- no test
    else
        local pos = #code + 1
        codecharset(code, cs, NOINST)
        local inst = code[pos]
        local code = inst.code
        if code == IFail then
            inst.code = IJmp -- always jump
        elseif code == IAny then
            inst.code = ITestAny
        elseif code == IChar then
            inst.code = ITestChar
        elseif code == ISet then
            inst.code = ITestSet
        else
            assert(false)
        end
        return pos
    end
end


-- Find the final destination of a sequence of jumps

local function finaltarget(code, i)
    while code[i].code == IJmp do
        i = i + code[i].offset
    end
    return i
end


-- final label (after traversing any jumps)

local function finallabel(code, i)
    return finaltarget(code, i + code[i].offset)
end

-- <behind(p)> == behind n; <p>   (where n = fixedlen(p))

local function codebehind(code, tree, index)
    if tree[index].val > 0 then
        addinstruction(code, IBehind, tree[index].val)
    end
    codegen(code, tree, fullset, false, NOINST, index + 1) --  NOINST
end


-- Choice; optimizations:
-- - when p1 is headfail
-- - when first(p1) and first(p2) are disjoint; than
-- a character not in first(p1) cannot go to p1, and a character
-- in first(p1) cannot go to p2 (at it is not in first(p2)).
-- (The optimization is not valid if p1 accepts the empty string,
-- as then there is no character at all...)
-- - when p2 is empty and opt is true; a IPartialCommit can resuse
-- the Choice already active in the stack.

local function codechoice(code, tree, fl, opt, p1, p2)
    local emptyp2 = tree[p2].tag == TTrue
    local e1, st1 = getfirst(tree, fullset, p1)
    local _, st2 = getfirst(tree, fl, p2)
    if headfail(tree, p1) or (e1 == 0 and cs_disjoint(st1, st2)) then
        -- <p1 / p2> == test (fail(p1)) -> L1 ; p1 ; jmp L2; L1: p2; L2:
        local test = codetestset(code, st1, 0)
        local jmp = NOINST;
        codegen(code, tree, fl, false, test, p1)
        if not emptyp2 then
            jmp = addinstruction(code, IJmp, 0)
        end
        jumptohere(code, test)
        codegen(code, tree, fl, opt, NOINST, p2)
        jumptohere(code, jmp)
    elseif opt and emptyp2 then
        -- p1? == IPartialCommit; p1
        jumptohere(code, addinstruction(code, IPartialCommit, 0))
        codegen(code, tree, fullset, true, NOINST, p1)
    else
        -- <p1 / p2> ==
        --  test(fail(p1)) -> L1; choice L1; <p1>; commit L2; L1: <p2>; L2:
        local test = codetestset(code, st1, e1)
        local pchoice = addinstruction(code, IChoice, 0)
        codegen(code, tree, fullset, emptyp2, test, p1)
        local pcommit = addinstruction(code, ICommit, 0)
        jumptohere(code, pchoice)
        jumptohere(code, test)
        codegen(code, tree, fl, opt, NOINST, p2)
        jumptohere(code, pcommit)
    end
end


-- And predicate
-- optimization: fixedlen(p) = n ==> <&p> == <p>; behind n
-- (valid only when 'p' has no captures)

local function codeand(code, tree, tt, index)
    local n = fixedlenx(tree, 0, 0, index)
    if n >= 0 and n <= MAXBEHIND and not hascaptures(tree, index) then
        codegen(code, tree, fullset, false, tt, index)
        if n > 0 then
            addinstruction(code, IBehind, n)
        end
    else -- default: Choice L1; p1; BackCommit L2; L1: Fail; L2:
        local pcommit;
        local pchoice = addinstruction(code, IChoice, 0)
        codegen(code, tree, fullset, false, tt, index)
        pcommit = addinstruction(code, IBackCommit, 0)
        jumptohere(code, pchoice)
        addinstruction(code, IFail, 0)
        jumptohere(code, pcommit)
    end
end


-- Captures: if pattern has fixed (and not too big) length, use
-- a single IFullCapture instruction after the match; otherwise,
-- enclose the pattern with OpenCapture - CloseCapture.

local function codecapture(code, tree, fl, tt, index)
    local len = fixedlenx(tree, 0, 0, index + 1)
    if len >= 0 and len <= MAXOFF and not hascaptures(tree, index + 1) then
        codegen(code, tree, fl, false, tt, index + 1)
        addinstcap(code, IFullCapture, tree[index].cap, tree[index].val, len)
    else
        addinstcap(code, IOpenCapture, tree[index].cap, tree[index].val, 0)
        codegen(code, tree, fl, false, tt, index + 1)
        addinstcap(code, ICloseCapture, Cclose, 0, 0)
    end
end


local function coderuntime(code, tree, tt, index)
    addinstcap(code, IOpenCapture, Cgroup, tree[index].val, 0)
    codegen(code, tree, fullset, false, tt, index + 1)
    addinstcap(code, ICloseRunTime, Cclose, 0, 0)
end


-- Repetion; optimizations:
-- When pattern is a charset, can use special instruction ISpan.
-- When pattern is head fail, or if it starts with characters that
-- are disjoint from what follows the repetions, a simple test
-- is enough (a fail inside the repetition would backtrack to fail
-- again in the following pattern, so there is no need for a choice).
-- When 'opt' is true, the repetion can reuse the Choice already
-- active in the stack.

local function coderep(code, tree, opt, fl, index)
    local st = tocharset(tree, index)
    if st then
        local op = coderealcharset(code, st)
        code[op].code = ISpan;
    else
        local e1, st = getfirst(tree, fullset, index)
        if headfail(tree, index) or (e1 == 0 and cs_disjoint(st, fl)) then
            -- L1: test (fail(p1)) -> L2; <p>; jmp L1; L2:
            local test = codetestset(code, st, 0)
            codegen(code, tree, fullset, opt, test, index)
            local jmp = addinstruction(code, IJmp, 0)
            jumptohere(code, test)
            jumptothere(code, jmp, test)
        else
            -- test(fail(p1)) -> L2; choice L2; L1: <p>; partialcommit L1; L2:
            -- or (if 'opt'): partialcommit L1; L1: <p>; partialcommit L1;
            local commit, l2;
            local test = codetestset(code, st, e1)
            local pchoice = NOINST;
            if opt then
                jumptohere(code, addinstruction(code, IPartialCommit, 0))
            else
                pchoice = addinstruction(code, IChoice, 0)
            end
            l2 = #code + 1
            codegen(code, tree, fullset, false, NOINST, index)
            commit = addinstruction(code, IPartialCommit, 0)
            jumptothere(code, commit, l2)
            jumptohere(code, pchoice)
            jumptohere(code, test)
        end
    end
end


-- Not predicate; optimizations:
-- In any case, if first test fails, 'not' succeeds, so it can jump to
-- the end. If pattern is headfail, that is all (it cannot fail
-- in other parts); this case includes 'not' of simple sets. Otherwise,
-- use the default code (a choice plus a failtwice).

local function codenot(code, tree, index)
    local e, st = getfirst(tree, fullset, index)
    local test = codetestset(code, st, e)
    if headfail(tree, index) then -- test (fail(p1)) -> L1; fail; L1:
        addinstruction(code, IFail, 0)
    else
        -- test(fail(p))-> L1; choice L1; <p>; failtwice; L1:
        local pchoice = addinstruction(code, IChoice, 0)
        codegen(code, tree, fullset, false, NOINST, index)
        addinstruction(code, IFailTwice, 0)
        jumptohere(code, pchoice)
    end
    jumptohere(code, test)
end


-- change open calls to calls, using list 'positions' to find
-- correct offsets; also optimize tail calls

local function correctcalls(code, positions, from, to)
    for i = from, to - 1 do
        if code[i].code == IOpenCall then
            local n = code[i].offset; -- rule number
            local rule = positions[n]; -- rule position
            assert(rule == from or code[rule - 1].code == IRet)
            if code[finaltarget(code, i + 1)].code == IRet then -- call; ret ?
                code[i].code = IJmp; -- tail call
            else
                code[i].code = ICall;
            end
            jumptothere(code, i, rule) -- call jumps to respective rule
        end
    end
end


-- Code for a grammar:
-- call L1; jmp L2; L1: rule 1; ret; rule 2; ret; ...; L2:

local function codegrammar(code, tree, index)
    local positions = {}
    local rulenumber = 1;
    local firstcall = addinstruction(code, ICall, 0) -- call initial rule
    local jumptoend = addinstruction(code, IJmp, 0) -- jump to the end
    jumptohere(code, firstcall) -- here starts the initial rule
    local rule = index + 1
    while tree[rule].tag == TRule do
        positions[rulenumber] = #code + 1 -- save rule position
        rulenumber = rulenumber + 1
        codegen(code, tree, fullset, false, NOINST, rule + 1) -- code rule
        addinstruction(code, IRet, 0)
        rule = rule + tree[rule].ps
    end
    assert(tree[rule].tag == TTrue)
    jumptohere(code, jumptoend)
    correctcalls(code, positions, firstcall + 2, #code + 1)
end


local function codecall(code, tree, index)
    local c = addinstruction(code, IOpenCall, 0) -- to be corrected later
    assert(tree[index + tree[index].ps].tag == TRule)
    setoffset(code, c, tree[index + tree[index].ps].cap) -- offset = rule number
end


local function codeseq(code, tree, fl, opt, tt, p1, p2)
    if needfollow(tree, p1) then
        local _, fll = getfirst(tree, fl, p2) -- p1 follow is p2 first
        codegen(code, tree, fll, false, tt, p1)
    else -- use 'fullset' as follow
        codegen(code, tree, fullset, false, tt, p1)
    end
    if (fixedlenx(tree, 0, 0, p1) ~= 0) then -- can p1 consume anything?
        tt = NOINST; -- invalidate test
    end
    codegen(code, tree, fl, opt, tt, p2)
end


-- Main code-generation function: dispatch to auxiliar functions
-- according to kind of tree

function codegen(code, tree, fl, opt, tt, index)
    local tag = tree[index].tag
    if tag == TChar then
        codechar(code, tree[index].val, tt)
    elseif tag == TAny then
        addinstruction(code, IAny, 0)
    elseif tag == TSet then
        codecharset(code, tree[index].val, tt)
    elseif tag == TTrue then
    elseif tag == TFalse then
        addinstruction(code, IFail, 0)
    elseif tag == TSeq then
        codeseq(code, tree, fl, opt, tt, index + 1, index + tree[index].ps)
    elseif tag == TChoice then
        codechoice(code, tree, fl, opt, index + 1, index + tree[index].ps)
    elseif tag == TRep then
        coderep(code, tree, opt, fl, index + 1)
    elseif tag == TBehind then
        codebehind(code, tree, index)
    elseif tag == TNot then
        codenot(code, tree, index + 1)
    elseif tag == TAnd then
        codeand(code, tree, tt, index + 1)
    elseif tag == TCapture then
        codecapture(code, tree, fl, tt, index)
    elseif tag == TRunTime then
        coderuntime(code, tree, tt, index)
    elseif tag == TGrammar then
        codegrammar(code, tree, index)
    elseif tag == TCall then
        codecall(code, tree, index)
    else
        assert(false)
    end
end


local function copy(c1, c2)
    c1.code = c2.code
    c1.val = c2.val
    c1.offset = c2.offset
end


-- Optimize jumps and other jump-like instructions.
-- * Update labels of instructions with labels to their final
-- destinations (e.g., choice L1; ... L1: jmp L2: becomes
-- choice L2)
-- * Jumps to other instructions that do jumps become those
-- instructions (e.g., jump to return becomes a return; jump
-- to commit becomes a commit)

local function peephole(code)
    local i = 1
    while i <= #code do
        local tag = code[i].code
        if tag == IChoice or tag == ICall or tag == ICommit or tag == IPartialCommit or
                tag == IBackCommit or tag == ITestChar or tag == ITestSet or tag == ITestAny then
            -- instructions with labels
            jumptothere(code, i, finallabel(code, i)) -- optimize label

        elseif tag == IJmp then
            local ft = finaltarget(code, i)
            local tag = code[ft].code -- jumping to what?
            if tag == IRet or tag == IFail or tag == IFailTwice or tag == IEnd then -- instructions with unconditional implicit jumps
                copy(code[i], code[ft]) -- jump becomes that instruction
            elseif tag == ICommit or tag == IPartialCommit or tag == IBackCommit then -- inst. with unconditional explicit jumps
                local fft = finallabel(code, ft)
                copy(code[i], code[ft]) -- jump becomes that instruction...
                jumptothere(code, i, fft) -- but must correct its offset
                i = i - 1 -- reoptimize its label
            else
                jumptothere(code, i, ft) -- optimize label
            end
        end
        i = i + 1
    end
end


-- Compile a pattern

local function compile(tree, index)
    local code = {}
    codegen(code, tree, fullset, false, NOINST, index)
    addinstruction(code, IEnd, 0)
    peephole(code)
    tree.code = code
end


-- ======================================================

return {
    checkaux = checkaux,
    tocharset = tocharset,
    fixedlenx = fixedlenx,
    hascaptures = hascaptures,
    compile = compile,
}