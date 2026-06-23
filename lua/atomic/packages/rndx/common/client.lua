---@class RNDX: Atomic.Package
local package = current()
local logger = package:getLogger()

local bit_band = bit.band
local surface_SetDrawColor = surface.SetDrawColor
local surface_SetMaterial = surface.SetMaterial
local surface_DrawTexturedRectUV = surface.DrawTexturedRectUV
local surface_DrawTexturedRect = surface.DrawTexturedRect
local render_CopyRenderTargetToTexture = render.CopyRenderTargetToTexture
local math_min = math.min
local math_max = math.max
local DisableClipping = DisableClipping

local SHADERS_VERSION = "SHADERS_VERSION_PLACEHOLDER"
local SHADERS_GMA = [========[SHADERS_GMA_PLACEHOLDER]========]
do
	local DECODED_SHADERS_GMA = util.Base64Decode(SHADERS_GMA)
	if (not DECODED_SHADERS_GMA or #DECODED_SHADERS_GMA == 0) then
		logger:err("failed to load shaders") -- this shouldn't happen
		return
	end

	file.Write("rndx_shaders_" .. SHADERS_VERSION .. ".gma", DECODED_SHADERS_GMA)
	game.MountGMA("data/rndx_shaders_" .. SHADERS_VERSION .. ".gma")
end

local function GET_SHADER(name)
	return SHADERS_VERSION:gsub("%.", "_") .. "_" .. name
end

local BLUR_RT = GetRenderTargetEx("RNDX" .. SHADERS_VERSION .. SysTime(),
	1024, 1024,
	RT_SIZE_LITERAL,
	MATERIAL_RT_DEPTH_SEPARATE,
	bit.bor(2, 256, 4, 8 --[[4, 8 is clamp_s + clamp-t]]),
	0,
	IMAGE_FORMAT_BGRA8888
)

local NEW_FLAG; do
	local flags_n = -1
	function NEW_FLAG()
		flags_n = flags_n + 1
		return 2 ^ flags_n
	end
end

local NO_TL, NO_TR, NO_BL, NO_BR           = NEW_FLAG(), NEW_FLAG(), NEW_FLAG(), NEW_FLAG()

-- Svetov/Jaffies's great idea!
local SHAPE_CIRCLE, SHAPE_FIGMA, SHAPE_IOS = NEW_FLAG(), NEW_FLAG(), NEW_FLAG()

local BLUR                                 = NEW_FLAG()

local shader_mat                           = [==[
screenspace_general
{
	$pixshader ""
	$vertexshader ""

	$basetexture ""
	$texture1    ""
	$texture2    ""
	$texture3    ""

	// Mandatory, don't touch
	$ignorez            1
	$vertexcolor        1
	$vertextransform    1
	"<dx90"
	{
		$no_draw 1
	}

	$copyalpha                 0
	$alpha_blend_color_overlay 0
	$alpha_blend               1 // for AA
	$linearwrite               1 // to disable broken gamma correction for colors
	$linearread_basetexture    1 // to disable broken gamma correction for textures
	$linearread_texture1       1 // to disable broken gamma correction for textures
	$linearread_texture2       1 // to disable broken gamma correction for textures
	$linearread_texture3       1 // to disable broken gamma correction for textures
}
]==]

local MATRIXES                             = {}

local function create_shader_mat(name, opts)
	assert(name and isstring(name), "create_shader_mat: tex must be a string")

	local key_values = util.KeyValuesToTable(shader_mat, false, true)

	if opts then
		for k, v in pairs(opts) do
			key_values[k] = v
		end
	end

	local mat = CreateMaterial(
		"rndx_shaders1" .. name .. SysTime(),
		"screenspace_general",
		key_values
	)

	MATRIXES[mat] = Matrix()

	return mat
end

local ROUNDED_MAT = create_shader_mat("rounded", {
	["$pixshader"] = GET_SHADER("rndx_rounded_ps30"),
	["$vertexshader"] = GET_SHADER("rndx_vertex_vs30"),
})
local ROUNDED_TEXTURE_MAT = create_shader_mat("rounded_texture", {
	["$pixshader"] = GET_SHADER("rndx_rounded_ps30"),
	["$vertexshader"] = GET_SHADER("rndx_vertex_vs30"),
	["$basetexture"] = "loveyoumom", -- if there is no base texture, you can't change it later
})

local BLUR_VERTICAL = "$c0_x"
local ROUNDED_BLUR_MAT = create_shader_mat("blur_horizontal", {
	["$pixshader"] = GET_SHADER("rndx_rounded_blur_ps30"),
	["$vertexshader"] = GET_SHADER("rndx_vertex_vs30"),
	["$basetexture"] = BLUR_RT:GetName(),
	["$texture1"] = "_rt_FullFrameFB",
})

local SHADOWS_MAT = create_shader_mat("rounded_shadows", {
	["$pixshader"] = GET_SHADER("rndx_shadows_ps30"),
	["$vertexshader"] = GET_SHADER("rndx_vertex_vs30"),
})

local SHADOWS_BLUR_MAT = create_shader_mat("shadows_blur_horizontal", {
	["$pixshader"] = GET_SHADER("rndx_shadows_blur_ps30"),
	["$vertexshader"] = GET_SHADER("rndx_vertex_vs30"),
	["$basetexture"] = BLUR_RT:GetName(),
	["$texture1"] = "_rt_FullFrameFB",
})

local SHAPES = {
	[SHAPE_CIRCLE] = 2,
	[SHAPE_FIGMA] = 2.2,
	[SHAPE_IOS] = 4,
}
local DEFAULT_SHAPE = SHAPE_FIGMA
local DEFAULT_BLUR_INTENSITY = 1.0

local MATERIAL_SetTexture = ROUNDED_MAT.SetTexture
local MATERIAL_SetMatrix = ROUNDED_MAT.SetMatrix
local MATERIAL_SetFloat = ROUNDED_MAT.SetFloat
local MATRIX_SetUnpacked = Matrix().SetUnpacked

local MAT
local X, Y, W, H
local TL, TR, BL, BR
local TEXTURE
local USING_BLUR, BLUR_INTENSITY
local COL_R, COL_G, COL_B, COL_A
local SHAPE, OUTLINE_THICKNESS
local START_ANGLE, END_ANGLE, ROTATION
local SHADOW_SPREAD, SHADOW_INTENSITY
local function RESET_PARAMS()
	MAT = nil
	X, Y, W, H = 0, 0, 0, 0
	TL, TR, BL, BR = 0, 0, 0, 0
	TEXTURE = nil
	USING_BLUR, BLUR_INTENSITY = false, DEFAULT_BLUR_INTENSITY
	COL_R, COL_G, COL_B, COL_A = 255, 255, 255, 255
	SHAPE, OUTLINE_THICKNESS = SHAPES[DEFAULT_SHAPE], -1
	START_ANGLE, END_ANGLE, ROTATION = 0, 360, 0
	CLIP_PANEL = nil
	SHADOW_SPREAD, SHADOW_INTENSITY = 0, 0
end

local normalize_corner_radii; do
	local HUGE = math.huge

	local function nzr(x)
		if x ~= x or x < 0 then return 0 end
		local lim = math_min(W, H)
		if x == HUGE then return lim end
		return x
	end

	local function clamp0(x) return x < 0 and 0 or x end

	function normalize_corner_radii()
		local TL, TR, BL, BR = nzr(TL), nzr(TR), nzr(BL), nzr(BR)

		local k = math_max(
			1,
			(TL + TR) / W,
			(BL + BR) / W,
			(TL + BL) / H,
			(TR + BR) / H
		)

		if k > 1 then
			local inv = 1 / k
			TL, TR, BL, BR = TL * inv, TR * inv, BL * inv, BR * inv
		end

		return clamp0(TL), clamp0(TR), clamp0(BL), clamp0(BR)
	end
end

local function SetupDraw()
	local TL, TR, BL, BR = normalize_corner_radii()

	local start_rad, sweep_rad
	local sweep = END_ANGLE - START_ANGLE
	if sweep >= 360 then
		start_rad, sweep_rad = 0, -1 -- full circle, shader skips arc math
	else
		if sweep < 0 then sweep = sweep + 360 end
		start_rad = (START_ANGLE % 360) * 0.017453292519943295
		sweep_rad = sweep * 0.017453292519943295
	end

	local matrix = MATRIXES[MAT]
	MATRIX_SetUnpacked(
		matrix,

		BL, W, OUTLINE_THICKNESS or -1, sweep_rad,
		BR, H, SHADOW_INTENSITY, ROTATION,
		TR, SHAPE, BLUR_INTENSITY or 1.0, 0,
		TL, TEXTURE and 1 or 0, start_rad, 0
	)
	MATERIAL_SetMatrix(MAT, "$viewprojmat", matrix)

	if COL_R then
		surface_SetDrawColor(COL_R, COL_G, COL_B, COL_A)
	end

	surface_SetMaterial(MAT)
end

local MANUAL_COLOR = NEW_FLAG()
local DEFAULT_DRAW_FLAGS = DEFAULT_SHAPE

local function draw_rounded(x, y, w, h, col, flags, tl, tr, bl, br, texture, thickness)
	if col and col.a == 0 then
		return
	end

	RESET_PARAMS()

	if not flags then
		flags = DEFAULT_DRAW_FLAGS
	end

	local using_blur = bit_band(flags, BLUR) ~= 0
	if using_blur then
		return package:drawBlur(x, y, w, h, flags, tl, tr, bl, br, thickness)
	end

	MAT = ROUNDED_MAT; if texture then
		MAT = ROUNDED_TEXTURE_MAT
		MATERIAL_SetTexture(MAT, "$basetexture", texture)
		TEXTURE = texture
	end

	W, H = w, h
	TL, TR, BL, BR = bit_band(flags, NO_TL) == 0 and tl or 0,
		bit_band(flags, NO_TR) == 0 and tr or 0,
		bit_band(flags, NO_BL) == 0 and bl or 0,
		bit_band(flags, NO_BR) == 0 and br or 0
	SHAPE = SHAPES[bit_band(flags, SHAPE_CIRCLE + SHAPE_FIGMA + SHAPE_IOS)] or SHAPES[DEFAULT_SHAPE]
	OUTLINE_THICKNESS = thickness

	if bit_band(flags, MANUAL_COLOR) ~= 0 then
		COL_R = nil
	elseif col then
		COL_R, COL_G, COL_B, COL_A = col.r, col.g, col.b, col.a
	else
		COL_R, COL_G, COL_B, COL_A = 255, 255, 255, 255
	end

	SetupDraw()

	-- https://github.com/Jaffies/rboxes/blob/main/rboxes.lua
	-- fixes setting $basetexture to ""(none) not working correctly
	return surface_DrawTexturedRectUV(x, y, w, h, -0.015625, -0.015625, 1.015625, 1.015625)
end

---@param rounding integer
---@param x integer
---@param y integer
---@param w integer
---@param h integer
---@param color? Color
---@param flags? integer
function package:draw(rounding, x, y, w, h, color, flags)
	return draw_rounded(x, y, w, h, color, flags, rounding, rounding, rounding, rounding)
end

---@param rounding integer
---@param x integer
---@param y integer
---@param w integer
---@param h integer
---@param color Color
---@param thickness? integer @default = 1
---@param flags? integer
function package:drawOutlined(rounding, x, y, w, h, color, thickness, flags)
	return draw_rounded(x, y, w, h, color, flags, rounding, rounding, rounding, rounding, nil, thickness or 1)
end

---@param rounding integer
---@param x integer
---@param y integer
---@param w integer
---@param h integer
---@param color Color
---@param texture ITexture
---@param flags? integer
function package:drawTexture(rounding, x, y, w, h, color, texture, flags)
	return draw_rounded(x, y, w, h, color, flags, rounding, rounding, rounding, rounding, texture)
end

---@param rounding integer
---@param x integer
---@param y integer
---@param w integer
---@param h integer
---@param color Color
---@param material IMaterial
---@param flags? integer
function package:drawMaterial(rounding, x, y, w, h, color, material, flags)
	local tex = material:GetTexture("$basetexture")

	if (tex) then
		return self:drawTexture(rounding, x, y, w, h, color, tex, flags)
	end
end

---@param x integer
---@param y integer
---@param radius integer
---@param color Color
---@param flags? integer
function package:drawCircle(x, y, radius, color, flags)
	return self:draw(radius / 2, x - radius / 2, y - radius / 2, radius, radius, color, (flags or 0) + SHAPE_CIRCLE)
end

---@param x integer
---@param y integer
---@param radius integer
---@param color Color
---@param thickness integer
---@param flags? integer
function package:drawCircleOutlined(x, y, radius, color, thickness, flags)
	return self:drawOutlined(radius / 2, x - radius / 2, y - radius / 2, radius, radius, color, thickness, (flags or 0) + SHAPE_CIRCLE)
end

---@param x integer
---@param y integer
---@param radius integer
---@param color Color
---@param texture ITexture
---@param flags? integer
function package:drawCircleTexture(x, y, radius, color, texture, flags)
	return self:drawTexture(radius / 2, x - radius / 2, y - radius / 2, radius, radius, color, texture, (flags or 0) + SHAPE_CIRCLE)
end

---@param x integer
---@param y integer
---@param radius integer
---@param color Color
---@param material IMaterial
---@param flags? integer
function package:drawCircleMaterial(x, y, radius, color, material, flags)
	return self:drawMaterial(radius / 2, x - radius / 2, y - radius / 2, radius, radius, color, material, (flags or 0) + SHAPE_CIRCLE)
end

local USE_SHADOWS_BLUR = false
local function draw_blur()
	if (USE_SHADOWS_BLUR) then
		MAT = SHADOWS_BLUR_MAT
	else
		MAT = ROUNDED_BLUR_MAT
	end

	COL_R, COL_G, COL_B, COL_A = 255, 255, 255, 255
	SetupDraw()

	render_CopyRenderTargetToTexture(BLUR_RT)
	MATERIAL_SetFloat(MAT, BLUR_VERTICAL, 0)
	surface_DrawTexturedRect(X, Y, W, H)

	render_CopyRenderTargetToTexture(BLUR_RT)
	MATERIAL_SetFloat(MAT, BLUR_VERTICAL, 1)
	surface_DrawTexturedRect(X, Y, W, H)
end

---@param x integer
---@param y integer
---@param w integer
---@param h integer
---@param flags? integer
---@param tl integer
---@param tr integer
---@param bl integer
---@param br integer
---@param thickness integer
function package:drawBlur(x, y, w, h, flags, tl, tr, bl, br, thickness)
	RESET_PARAMS()

	if (not flags) then
		flags = DEFAULT_DRAW_FLAGS
	end

	X, Y = x, y
	W, H = w, h
	TL, TR, BL, BR = bit_band(flags, NO_TL) == 0 and tl or 0,
		bit_band(flags, NO_TR) == 0 and tr or 0,
		bit_band(flags, NO_BL) == 0 and bl or 0,
		bit_band(flags, NO_BR) == 0 and br or 0
	SHAPE = SHAPES[bit_band(flags, SHAPE_CIRCLE + SHAPE_FIGMA + SHAPE_IOS)] or SHAPES[DEFAULT_SHAPE]
	OUTLINE_THICKNESS = thickness

	draw_blur()
end

local function setup_shadows()
	X = X - SHADOW_SPREAD
	Y = Y - SHADOW_SPREAD
	W = W + (SHADOW_SPREAD * 2)
	H = H + (SHADOW_SPREAD * 2)

	TL = TL + (SHADOW_SPREAD * 2)
	TR = TR + (SHADOW_SPREAD * 2)
	BL = BL + (SHADOW_SPREAD * 2)
	BR = BR + (SHADOW_SPREAD * 2)
end

local function draw_shadows(r, g, b, a)
	if USING_BLUR then
		USE_SHADOWS_BLUR = true
		draw_blur()
		USE_SHADOWS_BLUR = false
	end

	MAT = SHADOWS_MAT

	if r == false then
		COL_R = nil
	else
		COL_R, COL_G, COL_B, COL_A = r, g, b, a
	end

	SetupDraw()
	-- https://github.com/Jaffies/rboxes/blob/main/rboxes.lua
	-- fixes having no $basetexture causing uv to be broken
	surface_DrawTexturedRectUV(X, Y, W, H, -0.015625, -0.015625, 1.015625, 1.015625)
end

---@param x integer
---@param y integer
---@param w integer
---@param h integer
---@param color? Color
---@param flags? integer
---@param tl integer
---@param tr integer
---@param bl integer
---@param br integer
---@param spread? integer
---@param intensity? integer
---@param thickness? integer
function package:drawShadowsEx(x, y, w, h, color, flags, tl, tr, bl, br, spread, intensity, thickness)
	if (color and color.a == 0) then
		return
	end

	local OLD_CLIPPING_STATE = DisableClipping(true)

	RESET_PARAMS()

	if not flags then
		flags = DEFAULT_DRAW_FLAGS
	end

	X, Y = x, y
	W, H = w, h
	SHADOW_SPREAD = spread or 30
	SHADOW_INTENSITY = intensity or SHADOW_SPREAD * 1.2

	TL, TR, BL, BR = bit_band(flags, NO_TL) == 0 and tl or 0,
		bit_band(flags, NO_TR) == 0 and tr or 0,
		bit_band(flags, NO_BL) == 0 and bl or 0,
		bit_band(flags, NO_BR) == 0 and br or 0

	SHAPE = SHAPES[bit_band(flags, SHAPE_CIRCLE + SHAPE_FIGMA + SHAPE_IOS)] or SHAPES[DEFAULT_SHAPE]

	OUTLINE_THICKNESS = thickness

	setup_shadows()

	USING_BLUR = bit_band(flags, BLUR) ~= 0

	if (bit_band(flags, MANUAL_COLOR) ~= 0) then
		draw_shadows(false, nil, nil, nil)
	elseif (color) then
		draw_shadows(color.r, color.g, color.b, color.a)
	else
		draw_shadows(0, 0, 0, 255)
	end

	DisableClipping(OLD_CLIPPING_STATE)
end

---@param rounding integer
---@param x integer
---@param y integer
---@param w integer
---@param h integer
---@param color? Color
---@param spread? integer
---@param intensity? integer
---@param flags? integer
function package:drawShadows(rounding, x, y, w, h, color, spread, intensity, flags)
	return self:drawShadowsEx(x, y, w, h, color, flags, rounding, rounding, rounding, rounding, spread, intensity)
end

---@param rounding integer
---@param x integer
---@param y integer
---@param w integer
---@param h integer
---@param color? Color
---@param thickness? integer @default = 1
---@param spread? integer
---@param intensity? integer
---@param flags? integer
function package:drawShadowsOutlined(rounding, x, y, w, h, color, thickness, spread, intensity, flags)
	return self:drawShadowsEx(x, y, w, h, color, flags, rounding, rounding, rounding, rounding, spread, intensity, thickness or 1)
end

-- Flags
package.NO_TL = NO_TL
package.NO_TR = NO_TR
package.NO_BL = NO_BL
package.NO_BR = NO_BR

package.SHAPE_CIRCLE = SHAPE_CIRCLE
package.SHAPE_FIGMA = SHAPE_FIGMA
package.SHAPE_IOS = SHAPE_IOS

package.BLUR = BLUR
package.MANUAL_COLOR = MANUAL_COLOR

---@param flags integer
---@param flag integer
---@param bool boolean
function package:setFlag(flags, flag, bool)
	flag = self[flag] or flag
	if (tobool(bool)) then
		return bit.bor(flags, flag)
	else
		return bit.band(flags, bit.bnot(flag))
	end
end

---@param shape integer
function package:setDefaultShape(shape)
	DEFAULT_SHAPE = shape or SHAPE_FIGMA
	DEFAULT_DRAW_FLAGS = DEFAULT_SHAPE
end

---@param val integer
function package:setDefaultBlurIntensity(val)
	DEFAULT_BLUR_INTENSITY = math_max(0, tonumber(val) or 1.0)
end

---@return integer
function package:getDefaultBlurIntensity()
	return DEFAULT_BLUR_INTENSITY
end