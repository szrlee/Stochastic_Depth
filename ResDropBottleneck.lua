require 'nn'
require 'cudnn'
require 'cunn'
local nninit = require 'nninit'

local ResidualDrop, parent = torch.class('nn.ResidualDrop', 'nn.Container')

function ResidualDrop:__init(deathRate, nChannels, nOutChannels, stride)
    parent.__init(self)
    self.gradInput = torch.Tensor()
    self.gate = true
    self.train = true
    self.deathRate = deathRate
    nOutChannels = nOutChannels or nChannels
    nBottleneckChannels = nOutChannels / 4
    stride = stride or 1

    self.net = nn.Sequential()
    -- conv1x1
    if nChannels == nOutChannels then
        self.net:add(cudnn.SpatialBatchNormalization(nChannels))
        self.net:add(cudnn.ReLU(true))
    end
    self.net:add(cudnn.SpatialConvolution(nChannels, nBottleneckChannels, 1,1, stride,stride, 0,0)
                                             :init('weight', nninit.kaiming, {gain = 'relu'})
                                             :init('bias', nninit.constant, 0))

    -- conv3x3
    self.net:add(cudnn.SpatialBatchNormalization(nBottleneckChannels))
    self.net:add(cudnn.ReLU(true))
    self.net:add(cudnn.SpatialConvolution(nBottleneckChannels, nBottleneckChannels,
                                      3,3, 1,1, 1,1)
                                      :init('weight', nninit.kaiming, {gain = 'relu'})
                                      :init('bias', nninit.constant, 0))

    -- conv1x1
    self.net:add(cudnn.SpatialBatchNormalization(nBottleneckChannels))
    self.net:add(cudnn.ReLU(true))
    self.net:add(cudnn.SpatialConvolution(nBottleneckChannels, nOutChannels, 1,1, 1,1 , 0,0)
                                             :init('weight', nninit.kaiming, {gain = 'relu'})
                                             :init('bias', nninit.constant, 0))


    -- shortcut
    self.skip = nn.Sequential()
    if nOutChannels == nChannels then
        self.skip:add(nn.Identity())
    end
    --[[ if stride > 1 then
       -- optional downsampling
       self.skip:add(nn.SpatialAveragePooling(1, 1, stride,stride))
    end
    if nOutChannels > nChannels then
       -- optional padding, this is option A in their paper
       self.skip:add(nn.Padding(1, (nOutChannels - nChannels), 3))
    elseif nOutChannels < nChannels then
       print('Do not do this! nOutChannels < nChannels!')
    end]]

    if nOutChannels > nChannels then
       -- optional padding, this is option A in their paper
       self.skip:add(cudnn.SpatialConvolution(nChannels,nOutChannels,1,1,stride,stride,0,0)
                                             :init('weight', nninit.kaiming, {gain = 'relu'})
                                             :init('bias', nninit.constant, 0))
    elseif nOutChannels < nChannels then
       print('Do not do this! nOutChannels < nChannels!')
    end
    
    self.modules = {self.net, self.skip}
end

function ResidualDrop:updateOutput(input)
    local skip_forward = self.skip:forward(input)
    self.output:resizeAs(skip_forward):copy(skip_forward)
    if self.train then
      if self.gate then -- only compute convolutional output when gate is open
        --[[ Debug
            print('skip_forward\n', skip_forward:size())
            local net_forward = self.net:forward(input)
            print('net_forward\n', net_forward:size())]]
        self.output:add(self.net:forward(input))
      end
    else
      self.output:add(self.net:forward(input):mul(1-self.deathRate))
    end
    return self.output
end

function ResidualDrop:updateGradInput(input, gradOutput)
   self.gradInput = self.gradInput or input.new()
   self.gradInput:resizeAs(input):copy(self.skip:updateGradInput(input, gradOutput))
   if self.gate then
      self.gradInput:add(self.net:updateGradInput(input, gradOutput))
   end
   return self.gradInput
end

function ResidualDrop:accGradParameters(input, gradOutput, scale)
   scale = scale or 1
   if self.gate then
      self.net:accGradParameters(input, gradOutput, scale)
   end
end

---- Adds a residual block to the passed in model ----
function addResidualDrop(model, deathRate, nChannels, nOutChannels, stride)
   model:add(nn.ResidualDrop(deathRate, nChannels, nOutChannels, stride))
   return model
end
