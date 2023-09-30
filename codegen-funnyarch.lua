systemWordSize = 4
systemArgRegs = 8
return function(ir,asm)
    io.stdout:write(asm)

    local curFunc = ""
    local savedRegs = -1
    local argCount = 0
    local argUsage = 0
    local varSpace = 0
    local cursor = 1
    local callDepth = 0

    local function getSavedRegs(start)
        local i = start
        local highest = -1
        while ir[1][i][1] ~= "Return" do
            for _,val in ipairs(ir[1][i]) do
                if type(val) == "table" and val[1] == "saved" and val[2] > highest then
                    highest = val[2]
                end
            end
            i = i + 1
        end
        return highest+1
    end
    local function getArgUsage(start)
        local i = start
        local highest = -1
        while ir[1][i][1] ~= "Return" do
            for _,val in ipairs(ir[1][i]) do
                if type(val) == "table" and val[1] == "arg" and val[2] > highest then
                   highest = val[2]
                end
           end
           i = i + 1
        end
        return highest+1
    end
    local function getReg(t)
        if t[1] == "saved" then
            return "r"..(t[2]+8)
        elseif t[1] == "arg" then
            return "r"..t[2]
        elseif t[1] == "frame" then
            return "rfp"
        end
    end
    local function loadImm(r,i)
        -- // FIXME: negative values not supported
        if i < 0 then
            error("NOT IMPLEMENTED")
        end
        if i <= 0xFFFF then
            io.stdout:write("    mov "..r..", #"..i.."\n")
        else
            io.stdout:write("    mov "..r..", #"..(i & 0xFFFF).."\n")
            io.stdout:write("    movh "..r..", #"..((i >> 16) & 0xFFFF).."\n")
        end
    end
    local function labelTranslate(name)
        if name:sub(1,2) == ".L" then
            return curFunc.."_"..name:sub(3)
        else
            return name
        end
    end
    local ops = {}
    ops = {
        ["DefSymbol"]=function(name)
            io.stdout:write(name..":\n")
            curFunc = name
            savedRegs = getSavedRegs(cursor)
            argCount = ir[1][cursor+2][3]
            argUsage = math.max(argCount,getArgUsage(cursor))
            if savedRegs > (26 - 8) then
                error("ran out of saved registers")
            end
            if argCount > 8 then
                error("ran out of argument registers")
            end
        end,
        ["LocalLabel"]=function(name)
            io.stdout:write(labelTranslate(name)..":\n")
        end,
        ["PushRet"]=function()
            for i=argUsage,math.max(2,argCount+1),-1 do
                io.stdout:write("    strpi rsp, r"..(i-1)..", #-4\n")
            end
            for i=savedRegs,1,-1 do
                io.stdout:write("    strpi rsp, r"..(i+7)..", #-4\n")
            end
            io.stdout:write("    strpi rsp, lr, #-4\n")
            io.stdout:write("    strpi rsp, rfp, #-4\n")
        end,
        ["PushVariables"]=function(space,args)
            varSpace = space
            if (varSpace-(args*4)) ~= 0 then
                io.stdout:write("    sub rsp, #"..(varSpace-(args*4)).."\n")
            end
            for i=args,1,-1 do
                io.stdout:write("    strpi rsp, r"..(i-1)..", #-4\n")
            end
            io.stdout:write("    mov rfp, rsp\n")
            io.stdout:write("    sub rfp, #4\n")
        end,
        ["PopVariables"]=function()
            io.stdout:write(labelTranslate(".Lret")..":\n")
            if argCount > 1 then
                io.stdout:write("    add rsp, #4\n")
                for i=2,argCount do
                    io.stdout:write("    ldri r"..(i-1)..", rsp, #4\n")
                end
                if varSpace-(argCount*4) ~= 0 then
                    io.stdout:write("    add rsp, #"..varSpace-(argCount*4).."\n")
                end
            else
                if varSpace ~= 0 then
                    io.stdout:write("    add rsp, #"..varSpace.."\n")
                end
            end
        end,
        ["PopRet"]=function()
            io.stdout:write("    ldri rfp, rsp, #4\n")
            io.stdout:write("    ldri lr, rsp, #4\n")
            for i=1,savedRegs do
                io.stdout:write("    ldri r"..(i+7)..", rsp, #4\n")
            end
            for i=math.max(2,argCount+1),argUsage do
                io.stdout:write("    ldri r"..(i-1)..", rsp, #4\n")
            end
        end,
        ["Return"]=function()
            io.stdout:write("    mov rip, lr\n")
        end,
        ["BeginCall"]=function(r,argCount)
            callDepth = callDepth + 1
            if callDepth > 1 then
                if argCount > 0 and not (r[1] == "arg" and r[2] == 0) then
                    for i=1,argCount do
                        io.stdout:write("    strpi rsp, r"..(i-1)..", #-4\n")
                    end
                elseif r[1] == "arg" and r[2] ~= 0 then
                    io.stdout:write("    strpi rsp, r0, #-4\n")
                end
            end
        end,
        ["EndCall"]=function(name,argCount,r)
            if type(name) == "table" then
                error("NOT IMPLEMENTED")
                io.stdout:write("    call "..getReg(name).."\n")
            else
                io.stdout:write("    rjal "..name.."\n")
            end
            if r ~= nil then
                io.stdout:write("    mov "..getReg(r)..", r0\n") -- // TODO: optimisation (mov r0, r0)
            end
            if callDepth > 1 then
                if argCount > 0 and not (r[1] == "arg" and r[2] == 0) then
                    for i=argCount,1,-1 do
                        io.stdout:write("    ldri r"..(i-1)..", rsp, #4\n")
                    end
                elseif r[1] == "arg" and r[2] ~= 0 then
                    io.stdout:write("    ldri r0, rsp, #4\n")
                end
            end
            callDepth = callDepth - 1
        end,
        ["Move"]=function(r1,r2)
            io.stdout:write("    mov "..getReg(r2)..", "..getReg(r1).."\n")
        end,
        ["Add"]=function(r1,r2)
            if r2[1] == "number" then
                if r2[2] < 0 then
                    error("NOT IMPLEMENTED")
                end
                if r2[2] <= 0xFFFF then
                    io.stdout:write("    add "..getReg(r1)..", #"..r2[2].."\n")
                else
                    io.stdout:write("    add "..getReg(r1)..", #"..(r2[2] & 0xFFFF).."\n")
                    io.stdout:write("    addh "..getReg(r1)..", #"..((r2[2] >> 16) & 0xFFFF).."\n")
                end
            else
                io.stdout:write("    add "..getReg(r1)..", "..getReg(r1)..", "..getReg(r2).."\n")
            end
        end,
        ["Sub"]=function(r1,r2)
            if r2[1] == "number" then
                if r2[2] < 0 then
                    error("NOT IMPLEMENTED")
                end
                if r2[2] <= 0xFFFF then
                    io.stdout:write("    sub "..getReg(r1)..", #"..r2[2].."\n")
                else
                    io.stdout:write("    sub "..getReg(r1)..", #"..(r2[2] & 0xFFFF).."\n")
                    io.stdout:write("    subh "..getReg(r1)..", #"..((r2[2] >> 16) & 0xFFFF).."\n")
                end
            else
                io.stdout:write("    sub "..getReg(r1)..", "..getReg(r1)..", "..getReg(r2).."\n")
            end
        end,
        ["Mul"]=function(r1,r2,sign)
            if r2[1] == "number" then
                if (not sign) and (((math.log(r2[2]) / math.log(2))%1)==0) and ((math.log(r2[2]) / math.log(2)) < 32) then
                    io.stdout:write("    shl "..getReg(r1)..", "..getReg(r1)..", #"..math.floor((math.log(r2[2]) / math.log(2))).."\n")
                else
                    error("NOT IMPLEMENTED")
                    io.stdout:write("    "..(sign and "imul" or "mul").." "..getReg(r1)..", "..r2[2].."\n")
                end
            else
                error("NOT IMPLEMENTED")
                io.stdout:write("    "..(sign and "imul" or "mul").." "..getReg(r1)..", "..getReg(r2).."\n")
            end
        end,
        ["Div"]=function(r1,r2,sign)
            error("NOT IMPLEMENTED")
            if r2[1] == "number" then
                io.stdout:write("    "..(sign and "idiv" or "div").." "..getReg(r1)..", "..r2[2].."\n")
            else
                io.stdout:write("    "..(sign and "idiv" or "div").." "..getReg(r1)..", "..getReg(r2).."\n")
            end
        end,
        ["Mod"]=function(r1,r2,sign)
            error("NOT IMPLEMENTED")
            if r2[1] == "number" then
                io.stdout:write("    "..(sign and "irem" or "rem").." "..getReg(r1)..", "..r2[2].."\n")
            else
                io.stdout:write("    "..(sign and "irem" or "rem").." "..getReg(r1)..", "..getReg(r2).."\n")
            end
        end,
        ["And"]=function(r1,r2)
            if r2[1] == "number" then
                io.stdout:write("    and "..getReg(r1)..", #"..r2[2].."\n")
            else
                io.stdout:write("    and "..getReg(r1)..", "..getReg(r1)..", "..getReg(r2).."\n")
            end
        end,
        ["Or"]=function(r1,r2)
            if r2[1] == "number" then
                io.stdout:write("    or "..getReg(r1)..", #"..r2[2].."\n")
            else
                io.stdout:write("    or "..getReg(r1)..", "..getReg(r1)..", "..getReg(r2).."\n")
            end
        end,
        ["Xor"]=function(r1,r2)
            if r2[1] == "number" then
                io.stdout:write("    xor "..getReg(r1)..", #"..r2[2].."\n")
            else
                io.stdout:write("    xor "..getReg(r1)..", "..getReg(r1)..", "..getReg(r2).."\n")
            end
        end,
        ["Lsh"]=function(r1,r2)
            if r2[1] == "number" then
                io.stdout:write("    shl "..getReg(r1)..", "..getReg(r1)..", #"..r2[2].."\n")
            else
                io.stdout:write("    shl "..getReg(r1)..", "..getReg(r1)..", "..getReg(r2).."\n")
            end
        end,
        ["Rsh"]=function(r1,r2)
            if r2[1] == "number" then
                io.stdout:write("    shr "..getReg(r1)..", "..getReg(r1)..", #"..r2[2].."\n")
            else
                io.stdout:write("    shr "..getReg(r1)..", "..getReg(r1)..", "..getReg(r2).."\n")
            end
        end,
        ["Ash"]=function(r1,r2)
            error("NOT IMPLEMENTED")
            if r2[1] == "number" then
                io.stdout:write("    sra "..getReg(r1)..", "..r2[2].."\n")
            else
                io.stdout:write("    sra "..getReg(r1)..", "..getReg(r2).."\n")
            end
        end,
        ["Negate"]=function(r)
            error("NOT IMPLEMENTED")
            io.stdout:write("    not "..getReg(r).."\n")
            io.stdout:write("    inc "..getReg(r).."\n")
        end,
        ["Not"]=function(r)
            io.stdout:write("    not "..getReg(r)..", "..getReg(r).."\n")
        end,
        ["Eq"]=function(r1,r2)
            if r2[1] == "number" then
                io.stdout:write("    cmp "..getReg(r1)..", #"..r2[2].."\n")
            else
                io.stdout:write("    cmp "..getReg(r1)..", "..getReg(r2).."\n")
            end
            io.stdout:write("    ifz mov "..getReg(r1)..", #1\n")
            io.stdout:write("    ifnz mov "..getReg(r1)..", #0\n")
        end,
        ["Neq"]=function(r1,r2)
            if r2[1] == "number" then
                io.stdout:write("    cmp "..getReg(r1)..", #"..r2[2].."\n")
            else
                io.stdout:write("    cmp "..getReg(r1)..", "..getReg(r2).."\n")
            end
            io.stdout:write("    ifnz mov "..getReg(r1)..", #1\n")
            io.stdout:write("    ifz mov "..getReg(r1)..", #0\n")
        end,
        ["Lt"]=function(r1,r2,sign)
            if r2[1] == "number" then
                io.stdout:write("    cmp "..getReg(r1)..", #"..r2[2].."\n")
            else
                io.stdout:write("    cmp "..getReg(r1)..", "..getReg(r2).."\n")
            end
            io.stdout:write("    iflt mov "..getReg(r1)..", #1\n")
            io.stdout:write("    ifgteq mov "..getReg(r1)..", #0\n")
        end,
        ["Gt"]=function(r1,r2,sign)
            if r2[1] == "number" then
                io.stdout:write("    cmp "..getReg(r1)..", #"..r2[2].."\n")
            else
                io.stdout:write("    cmp "..getReg(r1)..", "..getReg(r2).."\n")
            end
            io.stdout:write("    ifgt mov "..getReg(r1)..", #1\n")
            io.stdout:write("    iflteq mov "..getReg(r1)..", #0\n")
        end,
        ["Le"]=function(r1,r2,sign)
            if r2[1] == "number" then
                io.stdout:write("    cmp "..getReg(r1)..", #"..r2[2].."\n")
            else
                io.stdout:write("    cmp "..getReg(r1)..", "..getReg(r2).."\n")
            end
            io.stdout:write("    iflteq mov "..getReg(r1)..", #1\n")
            io.stdout:write("    ifgt mov "..getReg(r1)..", #0\n")
        end,
        ["Ge"]=function(r1,r2,sign)
            if r2[1] == "number" then
                io.stdout:write("    cmp "..getReg(r1)..", #"..r2[2].."\n")
            else
                io.stdout:write("    cmp "..getReg(r1)..", "..getReg(r2).."\n")
            end
            io.stdout:write("    ifgteq mov "..getReg(r1)..", #1\n")
            io.stdout:write("    iflt mov "..getReg(r1)..", #0\n")
        end,
        ["StoreByte"]=function(d,offset,s)
            error("NOT IMPLEMENTED")
            if offset == 0 then
                io.stdout:write("    mov.8 ["..getReg(s).."], "..getReg(d).."\n")
            else
                if offset > 0 then
                    if offset > 127 then
                        io.stdout:write("    add "..getReg(s)..", "..offset.."\n")
                        io.stdout:write("    mov.8 ["..getReg(s).."], "..getReg(d).."\n")
                        if getReg(s) ~= getReg(d) then
                            io.stdout:write("    sub "..getReg(s)..", "..offset.."\n")
                        end
                    else
                        io.stdout:write("    mov.8 ["..getReg(s).."+"..offset.."], "..getReg(d).."\n")
                    end
                else
                    if offset < -128 then
                        io.stdout:write("    sub "..getReg(s)..", "..(-offset).."\n")
                        io.stdout:write("    mov.8 ["..getReg(s).."], "..getReg(d).."\n")
                        if getReg(s) ~= getReg(d) then
                            io.stdout:write("    add "..getReg(s)..", "..(-offset).."\n")
                        end
                    else
                        io.stdout:write("    mov.8 ["..getReg(s)..offset.."], "..getReg(d).."\n")
                    end
                end
            end
        end,
        ["StoreHalf"]=function(d,offset,s)
            error("NOT IMPLEMENTED")
            if offset == 0 then
                io.stdout:write("    mov.16 ["..getReg(s).."], "..getReg(d).."\n")
            else
                if offset > 0 then
                    if offset > 127 then
                        io.stdout:write("    add "..getReg(s)..", "..offset.."\n")
                        io.stdout:write("    mov.16 ["..getReg(s).."], "..getReg(d).."\n")
                        if getReg(s) ~= getReg(d) then
                            io.stdout:write("    sub "..getReg(s)..", "..offset.."\n")
                        end
                    else
                        io.stdout:write("    mov.16 ["..getReg(s).."+"..offset.."], "..getReg(d).."\n")
                    end
                else
                    if offset < -128 then
                        io.stdout:write("    sub "..getReg(s)..", "..(-offset).."\n")
                        io.stdout:write("    mov.16 ["..getReg(s).."], "..getReg(d).."\n")
                        if getReg(s) ~= getReg(d) then
                            io.stdout:write("    add "..getReg(s)..", "..(-offset).."\n")
                        end
                    else
                        io.stdout:write("    mov.16 ["..getReg(s)..offset.."], "..getReg(d).."\n")
                    end
                end
            end
        end,
        ["Store"]=function(d,offset,s)
            if offset == 0 then
                io.stdout:write("    str "..getReg(s)..", "..getReg(d)..", #"..offset.."\n")
            else
                if offset > 0 then
                    if offset > 4095 then
                        error("NOT IMPLEMENTED")
                        io.stdout:write("    add "..getReg(s)..", "..offset.."\n")
                        io.stdout:write("    mov.32 ["..getReg(s).."], "..getReg(d).."\n")
                        if getReg(s) ~= getReg(d) then
                            io.stdout:write("    sub "..getReg(s)..", "..offset.."\n")
                        end
                    else
                        io.stdout:write("    str "..getReg(s)..", "..getReg(d)..", #"..offset.."\n")
                    end
                else
                    if offset < -4096 then
                        error("NOT IMPLEMENTED")
                        io.stdout:write("    sub "..getReg(s)..", "..(-offset).."\n")
                        io.stdout:write("    mov.32 ["..getReg(s).."], "..getReg(d).."\n")
                        if getReg(s) ~= getReg(d) then
                            io.stdout:write("    add "..getReg(s)..", "..(-offset).."\n")
                        end
                    else
                        io.stdout:write("    str "..getReg(s)..", "..getReg(d)..", #"..offset.."\n")
                    end
                end
            end
        end,
        ["StoreLong"]=function(d,offset,s)
            if offset == 0 then
                io.stdout:write("    str "..getReg(s)..", "..getReg(d)..", #"..offset.."\n")
            else
                if offset > 0 then
                    if offset > 4095 then
                        error("NOT IMPLEMENTED")
                        io.stdout:write("    add "..getReg(s)..", "..offset.."\n")
                        io.stdout:write("    mov.32 ["..getReg(s).."], "..getReg(d).."\n")
                        if getReg(s) ~= getReg(d) then
                            io.stdout:write("    sub "..getReg(s)..", "..offset.."\n")
                        end
                    else
                        io.stdout:write("    str "..getReg(s)..", "..getReg(d)..", #"..offset.."\n")
                    end
                else
                    if offset < -4096 then
                        error("NOT IMPLEMENTED")
                        io.stdout:write("    sub "..getReg(s)..", "..(-offset).."\n")
                        io.stdout:write("    mov.32 ["..getReg(s).."], "..getReg(d).."\n")
                        if getReg(s) ~= getReg(d) then
                            io.stdout:write("    add "..getReg(s)..", "..(-offset).."\n")
                        end
                    else
                        io.stdout:write("    str "..getReg(s)..", "..getReg(d)..", #"..offset.."\n")
                    end
                end
            end
        end,
        ["LoadByte"]=function(d,offset,s)
            if offset == 0 then
                io.stdout:write("    ldr "..getReg(d)..", "..getReg(s)..", #"..offset.."\n")
                io.stdout:write("    and "..getReg(d)..", #0xFF\n")
            else
                if offset > 0 then
                    if offset > 4095 then
                        error("NOT IMPLEMENTED")
                        io.stdout:write("    add "..getReg(s)..", "..offset.."\n")
                        io.stdout:write("    movz.8 "..getReg(d)..", ["..getReg(s).."]\n")
                        if getReg(s) ~= getReg(d) then
                            io.stdout:write("    sub "..getReg(s)..", "..offset.."\n")
                        end
                    else
                        io.stdout:write("    ldr "..getReg(d)..", "..getReg(s)..", #"..offset.."\n")
                        io.stdout:write("    and "..getReg(d)..", #0xFF\n")
                    end
                else
                    if offset < -4096 then
                        error("NOT IMPLEMENTED")
                        io.stdout:write("    sub "..getReg(s)..", "..(-offset).."\n")
                        io.stdout:write("    movz.8 "..getReg(d)..", ["..getReg(s).."]\n")
                        if getReg(s) ~= getReg(d) then
                            io.stdout:write("    add "..getReg(s)..", "..(-offset).."\n")
                        end
                    else
                        io.stdout:write("    ldr "..getReg(d)..", "..getReg(s)..", #"..offset.."\n")
                        io.stdout:write("    and "..getReg(d)..", #0xFF\n")
                    end
                end
            end
        end,
        ["LoadHalf"]=function(d,offset,s)
            error("NOT IMPLEMENTED")
            if offset == 0 then
                io.stdout:write("    movz.16 "..getReg(d)..", ["..getReg(s).."]\n")
            else
                if offset > 0 then
                    if offset > 127 then
                        io.stdout:write("    add "..getReg(s)..", "..offset.."\n")
                        io.stdout:write("    movz.16 "..getReg(d)..", ["..getReg(s).."]\n")
                        if getReg(s) ~= getReg(d) then
                            io.stdout:write("    sub "..getReg(s)..", "..offset.."\n")
                        end
                    else
                        io.stdout:write("    movz.16 "..getReg(d)..", ["..getReg(s).."+"..offset.."]\n")
                    end
                else
                    if offset < -128 then
                        io.stdout:write("    sub "..getReg(s)..", "..(-offset).."\n")
                        io.stdout:write("    movz.16 "..getReg(d)..", ["..getReg(s).."]\n")
                        if getReg(s) ~= getReg(d) then
                            io.stdout:write("    add "..getReg(s)..", "..(-offset).."\n")
                        end
                    else
                        io.stdout:write("    movz.16 "..getReg(d)..", ["..getReg(s)..offset.."]\n")
                    end
                end
            end
        end,
        ["Load"]=function(d,offset,s)
            if offset == 0 then
                io.stdout:write("    ldr "..getReg(d)..", "..getReg(s)..", #"..offset.."\n")
            else
                if offset > 0 then
                    if offset > 4095 then
                        error("NOT IMPLEMENTED")
                        io.stdout:write("    add "..getReg(s)..", "..offset.."\n")
                        io.stdout:write("    mov.32 "..getReg(d)..", ["..getReg(s).."]\n")
                        if getReg(s) ~= getReg(d) then
                            io.stdout:write("    sub "..getReg(s)..", "..offset.."\n")
                        end
                    else
                        io.stdout:write("    ldr "..getReg(d)..", "..getReg(s)..", #"..offset.."\n")
                    end
                else
                    if offset < -4096 then
                        error("NOT IMPLEMENTED")
                        io.stdout:write("    sub "..getReg(s)..", "..(-offset).."\n")
                        io.stdout:write("    mov.32 "..getReg(d)..", ["..getReg(s).."]\n")
                        if getReg(s) ~= getReg(d) then
                            io.stdout:write("    add "..getReg(s)..", "..(-offset).."\n")
                        end
                    else
                        io.stdout:write("    ldr "..getReg(d)..", "..getReg(s)..", #"..offset.."\n")
                    end
                end
            end
        end,
        ["LoadLong"]=function(d,offset,s)
            error("NOT IMPLEMENTED")
            if offset == 0 then
                io.stdout:write("    mov.32 "..getReg(d)..", ["..getReg(s).."]\n")
            else
                if offset > 0 then
                    if offset > 127 then
                        io.stdout:write("    add "..getReg(s)..", "..offset.."\n")
                        io.stdout:write("    mov.32 "..getReg(d)..", ["..getReg(s).."]\n")
                        if getReg(s) ~= getReg(d) then
                            io.stdout:write("    sub "..getReg(s)..", "..offset.."\n")
                        end
                    else
                        io.stdout:write("    mov.32 "..getReg(d)..", ["..getReg(s).."+"..offset.."]\n")
                    end
                else
                    if offset < -128 then
                        io.stdout:write("    sub "..getReg(s)..", "..(-offset).."\n")
                        io.stdout:write("    mov.32 "..getReg(d)..", ["..getReg(s).."]\n")
                        if getReg(s) ~= getReg(d) then
                            io.stdout:write("    add "..getReg(s)..", "..(-offset).."\n")
                        end
                    else
                        io.stdout:write("    mov.32 "..getReg(d)..", ["..getReg(s)..offset.."]\n")
                    end
                end
            end
        end,
        ["LoadAddr"]=function(r,val)
            -- // FIXME: addresses over 16 bit
            io.stdout:write("    mov "..getReg(r)..", "..labelTranslate(val).."\n")
        end,
        ["LoadImmediate"]=function(r,val)
            loadImm(getReg(r),val)
        end,
        ["Branch"]=function(l)
            io.stdout:write("    rjmp "..labelTranslate(l).."\n")
        end,
        ["BranchIfZero"]=function(r,l)
            io.stdout:write("    cmp "..getReg(r)..", #0\n")
            io.stdout:write("    ifz rjmp "..labelTranslate(l).."\n")
        end,
        ["BranchIfNotZero"]=function(r,l)
            io.stdout:write("    cmp "..getReg(r)..", #0\n")
            io.stdout:write("    ifnz rjmp "..labelTranslate(l).."\n")
        end,
    }
    if useXrSDK then
        io.stdout:write(".section text\n")
    end
    while cursor <= #ir[1] do
        local insn = ir[1][cursor]
        if not ops[insn[1]] then
            error("Unknown IR Instruction: "..insn[1])
        else
            --local inspect = require('inspect')
            --print(string.format("IR: %s -- %s", insn[1], inspect({table.unpack(insn,2)})))
            ops[insn[1]](table.unpack(insn,2))
            --print("")
        end
        cursor = cursor + 1
    end
    if useXrSDK then
        io.stdout:write(".section rodata\n")
    end
    for _,i in ipairs(ir[2]) do
        if i[2] == "string" then
            io.stdout:write(i[1]..":\n")
            for j=1,#i[3] do
                if useXrSDK then
                    io.stdout:write(".db "..tostring(string.byte(string.sub(i[3],j,j))).." ")
                else
                    io.stdout:write(".byte "..tostring(string.byte(string.sub(i[3],j,j))).."\n")
                end
            end
            if useXrSDK then
                io.stdout:write(".db 0\n")
            else
                io.stdout:write(".byte 0\n")
            end
        elseif i[2] == "set" then
            io.stdout:write(i[1]..":\n")
            for _,j in ipairs(i[3]) do
                if useXrSDK then
                    io.stdout:write("    .dl "..j[2].."\n")
                else
                    io.stdout:write("    data.32 "..j[2].."\n")
                end
            end
        end
    end
    if useXrSDK then
        io.stdout:write(".section bss\n")
    end
    for _,i in ipairs(ir[3]) do
        if useXrSDK then
            io.stdout:write(i[1]..": .bytes "..i[2].." 0\n")
        else
            io.stdout:write(i[1]..":\n")
            for j = 1, i[2] do
                io.stdout:write(".byte 0\n")
            end
        end
    end
end
