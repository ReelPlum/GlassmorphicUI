local RunService = game:GetService("RunService")

local EditableImageBlur, PixelColorApproximation
if script:FindFirstChild("Packages") then
	-- Built as a stand-alone model
	EditableImageBlur = require(script.Packages.EditableImageBlur)
	PixelColorApproximation = require(script.Packages.PixelColorApproximation)
elseif
	script.Parent:FindFirstChild("EditableImageBlur") and script.Parent:FindFirstChild("PixelColorApproximation")
then
	-- Installed via wally
	EditableImageBlur = require(script.Parent.EditableImageBlur)
	PixelColorApproximation = require(script.Parent.PixelColorApproximation)
else
	error("Could not find required packages")
end

local EMPTY_TABLE = {}

type GlassObject = {
	Window: ImageLabel,
	EditableImage: EditableImage,
	Pixels: { number },
	PixelIndex: number,
	InterlaceOffsetFlag: boolean,
	Resolution: Vector2,
	ResolutionInverse: Vector2,
	WindowSizeX: number,
	WindowSizeY: number,
	WindowPositionX: number,
	WindowPositionY: number,
	WindowColor: { number },
}

local GlassmorphicUI = {}

GlassmorphicUI._glassObjects = {} :: { GlassObject }
GlassmorphicUI._glassObjectUpdateIndex = 1

GlassmorphicUI.MAX_AXIS_SAMPLING_RES = 39
GlassmorphicUI.UPDATE_TIME_BUDGET = 0.002
GlassmorphicUI.RADIUS = 5
GlassmorphicUI.TEMPORAL_SMOOTHING = 0.75

function GlassmorphicUI.new(Window: ImageLabel | ImageButton?): ImageLabel
	if not Window then
		Window = Instance.new("ImageLabel")
		-- Some reasonable defaults
		Window.Size = UDim2.fromScale(50, 30)
		Window.BackgroundColor3 = Color3.fromRGB(130, 215, 255)
		Window.BorderSizePixel = 0
		Window.BackgroundTransparency = 0.8
		Window.Name = "GlassmorphicUI"
	end

	local EditableImage = Instance.new("EditableImage")
	EditableImage.Parent = Window

	local glassObject = {
		Window = Window,
		EditableImage = EditableImage,
		Pixels = {},
		PixelIndex = 1,
		InterlaceOffsetFlag = false,
		Resolution = Vector2.one,
		ResolutionInverse = Vector2.one,
		WindowSizeX = 1,
		WindowSizeY = 1,
		WindowPositionX = 0,
		WindowPositionY = 0,
		WindowColor = {
			Window.BackgroundColor3.R,
			Window.BackgroundColor3.G,
			Window.BackgroundColor3.B,
			1 - Window.BackgroundTransparency,
		},
	}

	GlassmorphicUI:watchProperties(glassObject)

	Window.Destroying:Connect(function()
		local index = table.find(GlassmorphicUI._glassObjects, glassObject)
		if index then
			table.remove(GlassmorphicUI._glassObjects, index)
		end
	end)

	local initializeConnection
	initializeConnection = Window.AncestryChanged:Connect(function()
		if not Window:IsDescendantOf(game) then
			return
		end

		initializeConnection:Disconnect()

		-- Wait for window properties to load
		while Window.AbsoluteSize.X == 0 do
			task.wait()
		end

		GlassmorphicUI:updateWindowColor(glassObject)
		GlassmorphicUI:updateWindowPosition(glassObject)
		GlassmorphicUI:updateWindowSize(glassObject)

		table.insert(GlassmorphicUI._glassObjects, glassObject)
	end)

	return Window
end

function GlassmorphicUI:watchProperties(glassObject: GlassObject)
	local Window = glassObject.Window

	Window:GetPropertyChangedSignal("AbsolutePosition"):Connect(function()
		GlassmorphicUI:updateWindowPosition(glassObject)
	end)
	Window:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		GlassmorphicUI:updateWindowSize(glassObject)
	end)
	Window:GetPropertyChangedSignal("BackgroundColor3"):Connect(function()
		GlassmorphicUI:updateWindowColor(glassObject)
	end)
	Window:GetPropertyChangedSignal("BackgroundTransparency"):Connect(function()
		GlassmorphicUI:updateWindowColor(glassObject)
	end)
end

function GlassmorphicUI:updateWindowPosition(glassObject: GlassObject)
	local Window = glassObject.Window
	local absolutePosition = Window.AbsolutePosition
	glassObject.WindowPositionX = absolutePosition.X
	glassObject.WindowPositionY = absolutePosition.Y
end

function GlassmorphicUI:updateWindowColor(glassObject: GlassObject)
	local Window = glassObject.Window
	local windowAlpha = 1 - Window.BackgroundTransparency
	local windowColor = Window.BackgroundColor3
	glassObject.WindowColor[1] = windowColor.R
	glassObject.WindowColor[2] = windowColor.G
	glassObject.WindowColor[3] = windowColor.B
	glassObject.WindowColor[4] = windowAlpha
end

function GlassmorphicUI:updateWindowSize(glassObject: GlassObject)
	local Window = glassObject.Window

	local absoluteSize = Window.AbsoluteSize
	local windowSizeX, windowSizeY = absoluteSize.X, absoluteSize.Y

	if windowSizeX == 0 or windowSizeY == 0 then
		return
	end

	glassObject.WindowSizeX = windowSizeX
	glassObject.WindowSizeY = windowSizeY

	local maxAxis = math.max(windowSizeX, windowSizeY)
	local samplerSize = maxAxis / math.min(self.MAX_AXIS_SAMPLING_RES, maxAxis)

	local resolutionX, resolutionY = windowSizeX // samplerSize, windowSizeY // samplerSize
	local inverseResX, inverseResY = 1 / resolutionX, 1 / resolutionY

	glassObject.Resolution = Vector2.new(resolutionX, resolutionY)
	glassObject.ResolutionInverse = Vector2.new(inverseResX, inverseResY)
	glassObject.EditableImage.Size = glassObject.Resolution

	-- Ensure the pixels array is correct size
	local Pixels = glassObject.Pixels
	local WindowColor = glassObject.WindowColor

	local pixelsArrayLength = resolutionX * resolutionY * 4
	local pixelsArrayCurrentLength = #Pixels
	if pixelsArrayCurrentLength > pixelsArrayLength then
		-- Remove extra pixel data by moving empties in after the pixelsArrayLength
		table.move(EMPTY_TABLE, 1, pixelsArrayCurrentLength - pixelsArrayLength, pixelsArrayLength + 1, Pixels)
	elseif pixelsArrayCurrentLength < pixelsArrayLength then
		-- Add new pixels
		for i = pixelsArrayCurrentLength + 1, pixelsArrayLength do
			local mod4 = i % 4
			if mod4 == 0 then
				-- Fully opaque alpha channel
				Pixels[i] = 1
			else
				Pixels[i] = WindowColor[mod4] or 1
			end
		end
	end

	-- Move index back to start if new size is smaller
	if glassObject.PixelIndex > pixelsArrayLength then
		glassObject.PixelIndex = if glassObject.InterlaceOffsetFlag then 1 else 5
	end
end

function GlassmorphicUI:processNextPixel(glassObject: GlassObject)
	local Window = glassObject.Window
	if (not Window) or (not Window:IsDescendantOf(game)) then
		return
	end

	local Pixels, PixelIndex = glassObject.Pixels, glassObject.PixelIndex
	local WindowColor = glassObject.WindowColor

	if WindowColor[4] == 1 then
		-- Our window is not transparent, so there's no need to sample underneath
		-- (It's also not glassmorphic anymore, but that's not our problem)

		-- Set entire image to window color
		local r, g, b = WindowColor[1], WindowColor[2], WindowColor[3]
		for i = 1, #Pixels, 4 do
			Pixels[i] = r
			Pixels[i + 1] = g
			Pixels[i + 2] = b
		end

		-- Move index back to start
		glassObject.PixelIndex = if glassObject.InterlaceOffsetFlag then 1 else 5
		return
	end

	local Resolution = glassObject.Resolution
	local ResolutionInverse = glassObject.ResolutionInverse
	local WindowSizeX, WindowSizeY = glassObject.WindowSizeX, glassObject.WindowSizeY
	local WindowPositionX, WindowPositionY = glassObject.WindowPositionX, glassObject.WindowPositionY

	-- Sample color at the center of our sample
	local indexFloor4 = PixelIndex // 4
	local color = PixelColorApproximation:GetColor(
		Vector2.new(
			(ResolutionInverse.X * (indexFloor4 % Resolution.X) * WindowSizeX + WindowPositionX)
				+ (WindowSizeX * ResolutionInverse.X / 2),
			(ResolutionInverse.Y * (indexFloor4 // Resolution.X) * WindowSizeY + WindowPositionY)
				+ (WindowSizeY * ResolutionInverse.Y / 2)
		),
		Window
	)

	-- Blend window color on top
	local windowAlpha = WindowColor[4]
	color[1] = (1 - windowAlpha) * color[1] + windowAlpha * WindowColor[1]
	color[2] = (1 - windowAlpha) * color[2] + windowAlpha * WindowColor[2]
	color[3] = (1 - windowAlpha) * color[3] + windowAlpha * WindowColor[3]

	local prevR, prevG, prevB = Pixels[PixelIndex], Pixels[PixelIndex + 1], Pixels[PixelIndex + 2]
	Pixels[PixelIndex] = prevR + (color[1] - prevR) * self.TEMPORAL_SMOOTHING
	Pixels[PixelIndex + 1] = prevG + (color[2] - prevG) * self.TEMPORAL_SMOOTHING
	Pixels[PixelIndex + 2] = prevB + (color[3] - prevB) * self.TEMPORAL_SMOOTHING
	--Pixels[pixelIndex + 3] = color[4]

	PixelIndex += 8
	if PixelIndex > #Pixels then
		glassObject.InterlaceOffsetFlag = not glassObject.InterlaceOffsetFlag
		PixelIndex = if glassObject.InterlaceOffsetFlag then 1 else 5
	end

	glassObject.PixelIndex = PixelIndex
end

function GlassmorphicUI:update()
	local totalGlassObjects = #self._glassObjects
	if totalGlassObjects == 0 then
		return
	end

	local startClock = os.clock()

	-- Process pixels until time is up
	while os.clock() - startClock < self.UPDATE_TIME_BUDGET do
		local glassObject = self._glassObjects[self._glassObjectUpdateIndex]
		if glassObject then
			self:processNextPixel(glassObject)
		end
		self._glassObjectUpdateIndex += 1

		if self._glassObjectUpdateIndex > totalGlassObjects then
			self._glassObjectUpdateIndex = 1
		end
	end

	-- Apply the pixels to the images with blur
	for _, glassObject in self._glassObjects do
		EditableImageBlur({
			image = glassObject.EditableImage,
			pixelData = glassObject.Pixels,
			blurRadius = self.RADIUS,
			downscaleFactor = 1,
			skipAlpha = true,
		})
	end
end

RunService.Heartbeat:Connect(function()
	GlassmorphicUI:update()
end)

return GlassmorphicUI
