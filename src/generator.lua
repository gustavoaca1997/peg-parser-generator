local re = require"relabel"
local lp = require"lpeglabel"
local parser = require"caribay.parser"

lp.locale(lp) -- adds locale entries into 'lpeglabel' table
----------------------------------------------------------------------------
----------------------------------------------------------------------------

-- Module to export
local M = {}

function M.unique_token_prefix(literals_map)
    local literals_arr = {}     -- ordered array with the unique literals.
    local literals_patterns = {}  -- map of not predicates of array of tokens for which they are prefixes.

    for literal_str in pairs(literals_map) do 
        table.insert(literals_arr, literal_str) 
        literals_patterns[literal_str] = lp.P(literal_str)
    end
    table.sort(literals_arr)

    --[[
        For each token `literal_str`, if it's a prefix of a token `literal_str_1`,
        then add `literal_str_1` to the array of `literal_str`.
    ]]
    for idx, literal_str in ipairs(literals_arr) do
        for jdx = idx+1, #literals_arr do

            local literal_str_1 = literals_arr[jdx]

            if literal_str_1:find(literal_str, 1, true) then
                literals_patterns[literal_str] = literals_patterns[literal_str] - lp.P(literal_str_1)
            else
                break
            end
        end
    end

    return literals_patterns
end

----------------------------------------------------------------------------
----------------------------------------------------------------------------

-- Generator class
local Generator = {}

function Generator:new(actions, literals_map)

    -- Create new object
    local obj = {
        actions = actions or {},
        keywords = {},
        syms = {},
        grammar = {},
        literals_patterns = M.unique_token_prefix(literals_map),
    }

    -- Inherit from `Generator`
    self.__index = self
    setmetatable(obj, self)
    return obj
end

-- generators for each kind of node
local generator = {}

----------------------------------------------------------------------------
------------------------- Auxiliar functions -------------------------------
----------------------------------------------------------------------------

local function parent_node_if_necessary(tag)
    return function ( captures )
        if (#captures == 1) then
            return captures[1]
        else
            captures.tag = tag
            return captures
        end
    end
end

function Generator:dont_match_keyword(subject, pos, ast_node)
    --[[
        Match ID if it is not a keyword
    ]]
    local identifier = ast_node[1]
    if self.keywords[identifier] then
        return false
    else
        return true, ast_node
    end
end

function Generator:unique_lex(literal_str, sym, is_only_child)
    --[[
        Ensures unique token prefix property for the token
        `literal_str`.
    ]]
    if is_only_child or sym:is_syn() then
        return self.literals_patterns[literal_str]
    else
        return lp.P(literal_str)
    end
end

----------------------------------------------------------------------------
----------------------------------------------------------------------------

-- Symbol class
local Symbol = {
    is_fragment = false,
    is_keyword = false,
    is_skippable = false,
    rule_no = 0,
}

function Symbol:is_lex()
    return self.type == 'lex'
end

function Symbol:is_syn()
    return self.type == 'syn'
end

function Symbol:new(sym_str, type, is_fragment, is_keyword, is_skippable, rule_no)
    local obj = {
        sym_str = sym_str,
        type = type,
        is_fragment = is_fragment,
        is_keyword = is_keyword,
        is_skippable = is_skippable,
        rule_no = rule_no,
    }
    self.__index = self
    setmetatable(obj, self)
    return obj
end

----------------------------------------------------------------------------
----------------------------------------------------------------------------

function Generator:get_syms (ast)
    --[[
        From AST, store in the module table the symbols with 
        info about their types and annotations.
    ]]
    local syms = {
        SKIP = Symbol:new('SKIP', 'syn', true),
        ID_START = Symbol:new('ID_START', 'lex', true),
        ID_END = Symbol:new('ID_END', 'lex', true),
        ID = Symbol:new('ID', 'lex'),
    }

    for idx, rule in ipairs(ast) do
        local sym = rule[1]
        local sym_str = sym[1]
        local type = sym.tag == 'syn_sym' and 'syn' or 'lex'
        local is_fragment = rule.fragment and true or false     -- rule.fragment is "true" or nil
        local is_keyword = rule.keyword and true or false       -- rule.keyword is "true" or nil
        local is_skippable = rule.skippable and true or false

        -- Save first symbol as first rule
        if #self.grammar == 0 and not is_fragment then
            self.grammar[1] = sym[1]
        end

        -- Save rule
        syms[sym_str] = syms[sym_str] or 
                        Symbol:new(sym_str, type, is_fragment, 
                                is_keyword, is_skippable, idx)
        
    end
    self.syms = syms
    return self.syms
end

function Generator:to_lpeg(node, sym, is_only_child)
    --[[
        Generates LPegLabel expression from the
        ast node and the lhs of the current rule.
        It uses the table `generator`.

        If `is_unique` is true, this node is 
        considered as the only child of the parent node.
    ]]
    return generator[node.tag](self, node, sym, is_only_child)
end

local function from_tag(tag)
    --[[
        To add the field 'tag' with the name or type
        of the node.
    ]]
    return lp.Cg(lp.P('') / tag, 'tag') * lp.Cg(lp.Cp(), 'pos')
end

function Generator:gen_auxiliars()
    --[[
        Generate auxiliar rules if are not defined by the user yet.
    ]]

    -- Generate a 'SKIP' rule
    if not self.grammar['SKIP'] then
        if self.grammar['COMMENT'] then
            self.grammar['SKIP'] = (lp.space + lp.V'COMMENT' / 0)^0
        else
            self.grammar['SKIP'] = lp.space^0
        end
    end

    -- Add initial SKIP to initial symbol
    local init_sym = self.grammar[1]
    self.grammar[init_sym] = lp.V'SKIP' * self.grammar[init_sym]

    -- Generate an 'ID_START' rule
    if not self.grammar['ID_START'] then
        self.grammar['ID_START'] = re.compile('[a-zA-Z]')
    end

    -- Generate an 'ID_END' rule
    if not self.grammar['ID_END'] then
        self.grammar['ID_END'] = re.compile('[a-zA-Z0-9_]+')
    end

    -- Generate 'ID' rule
    local capture = lp.C( lp.V'ID_START' * lp.V'ID_END'^-1 )
    self.grammar['ID'] = lp.Cmt( lp.Ct( from_tag('ID') * capture ), function(...) return self:dont_match_keyword(...) end )

end

local function throw_error(err, sym)
    error('Rule ' .. sym.sym_str .. ': ' .. err)
end

local function to_keyword(pattern)
    return pattern * (-lp.V'ID_END')
end

local SKIP_var = lp.V'SKIP'

local function add_SKIP(pattern, sym)
    local SKIP_var = sym:is_syn() and SKIP_var or lp.P('')
    return pattern * SKIP_var
end

local function capt_if_syn(pattern, sym)
    return sym:is_syn() and lp.C(pattern) or pattern
end

----------------------------------------------------------------------------
------------------- Generators for each AST tag ----------------------------
----------------------------------------------------------------------------

generator['rule'] = function(self, node) 
    local sym_str = node[1][1]  -- Name of the symbol
    local sym = self.syms[sym_str] -- Symbol 'object'
    local rhs = node[2]
    local is_only_child = rhs.tag == 'literal' or rhs.tag == 'keyword'
    local rhs_lpeg = self:to_lpeg(rhs, sym, is_only_child)

    if sym.is_keyword then
        rhs_lpeg = to_keyword(rhs_lpeg)
    end

    if sym.is_fragment then
        self.grammar[sym_str] = rhs_lpeg
    else
        -- If it's a lexical rule, capture all RHS.
        rhs_lpeg = sym:is_lex() and lp.C(rhs_lpeg / 0) or rhs_lpeg

        -- If it's skippable, don't capture if it only has one child
        if sym.is_skippable then
            self.grammar[sym_str] = lp.Ct( lp.Cg(lp.Cp(), 'pos') * rhs_lpeg ) / parent_node_if_necessary(sym_str)
        else
            self.grammar[sym_str] = lp.Ct( from_tag(sym_str) * rhs_lpeg )
        end
    end
end

generator['lex_sym'] = function(self, node, sym)
    local lex = node[1]
    local lex_sym = self.syms[lex]
    return add_SKIP(lp.V(lex), sym)

end

generator['syn_sym'] = function(self, node, sym)
    local syn = node[1]
    local syn_sym = self.syms[syn]
    if sym:is_lex() then
        throw_error('Trying to use a syntactic element in a lexical rule', sym)
    else
        return lp.V(syn)
    end
end

generator['ord_exp'] = function(self, node, sym)
    local ret = self:to_lpeg(node[1], sym)
    for i = 2, #node do
        local exp = node[i]
        ret = ret + self:to_lpeg(exp, sym)
    end
    return ret
end

generator['seq_exp'] = function(self, node, sym)
    local ret = lp.P('')
    for _, exp in ipairs(node) do
        ret = ret * self:to_lpeg(exp, sym)
    end
    return ret
end

generator['back_exp'] = function(self, node, sym)
    return lp.Cb(node[1])
end

generator['star_exp'] = function(self, node, sym)
    local exp_lpeg = self:to_lpeg(node[1], sym)
    return exp_lpeg^0
end

generator['rep_exp'] = function(self, node, sym)
    local exp_lpeg = self:to_lpeg(node[1], sym)
    return exp_lpeg^1
end

generator['opt_exp'] = function(self, node, sym)
    local exp_lpeg = self:to_lpeg(node[1], sym)
    return exp_lpeg^-1
end

generator['not_exp'] = function(self, node, sym)
    local exp_lpeg = self:to_lpeg(node[1], sym)
    return -exp_lpeg
end

generator['and_exp'] = function(self, node, sym)
    local exp_lpeg = self:to_lpeg(node[1], sym)
    return #exp_lpeg
end

generator['literal'] = function(self, node, sym, is_only_child)
    local literal_str = node[1]
    local literal_lpeg = self:unique_lex(literal_str, sym, is_only_child)

    if sym:is_lex() or not node.captured then
        return add_SKIP(literal_lpeg, sym)
    else
        return add_SKIP(lp.Ct( from_tag('token') * lp.C(literal_lpeg) ), sym)
    end
end

generator['keyword'] = function(self, node, sym, is_only_child)
    local literal_str = node[1]
    local literal_lpeg = self:unique_lex(literal_str, sym, is_only_child)

    -- Keep track of kwywords
    self.keywords[literal_str] = true

    local pattern = to_keyword(literal_lpeg)
    if sym:is_syn() then
        pattern = lp.Ct( from_tag('token') * lp.C(pattern) )
    end
    return add_SKIP(pattern, sym)
end

generator['class'] = function(self, node, sym)
    local chr_class = node[1]
    local lpeg_class = re.compile(chr_class)
    return capt_if_syn(lpeg_class, sym)
end

generator['any'] = function(self, node, sym)
    local lpeg_class = lp.P(1)
    return capt_if_syn(lpeg_class, sym)
end

generator['empty'] = function(self, node, sym)
    return lp.P('')
end

generator['action'] = function(self, node, sym)
    local action_name = node.action
    local action = self.actions[action_name]
    local exp_lpeg = self:to_lpeg(node[1], sym)
    return lp.Cmt(exp_lpeg, action)
end

generator['group'] = function(self, node, sym)
    local group_name = node.group
    local exp_lpeg = self:to_lpeg(node[1], sym)
    return lp.Cg(exp_lpeg, group_name)
end

----------------------------------------------------------------------------
----------------------------------------------------------------------------

M.gen = function (input, actions)
    local ast, literals = parser.match(input)
    local generator = Generator:new(actions, literals)
    generator:get_syms(ast)

    for _, rule in ipairs(ast) do
        generator:to_lpeg(rule)
    end
    generator:gen_auxiliars()

    return lp.P(generator.grammar) * -1
end

return M