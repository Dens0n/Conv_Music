require 'midiparse'
require 'lfs'
require 'optim'
require 'tools'
require 'xlua'
require 'rnn'
json = require 'json'

opt = get_args(arg, false)

require 'validate'

if opt.opencl then
	require 'cltorch'
	require 'clnn'
else
	require 'torch'
	require 'nn'
end

DATA_WIDTH = 89
curr_ep = 1
start_ep = 0
start_index = 1

loss = 0
valid_loss = 0
batches = 0 --TODO Can be constant, probably somehow

resume = false

meta = {bs=opt.bs,
		rho=opt.rho,
		ep=opt.ep,
		dl=opt.dl,
		rl=opt.rl,
		hs=opt.hs,
		drop=opt.drop,
		lr=opt.lr,
		lrd=opt.lrd,
		wd=opt.wd,
		d=opt.d,
		vd=opt.vd,
		opencl=opt.opencl
}

-- Min-Maxed logarithms for data with long tail
-- x_n = (ln(x+1)-ln(x_min)) / (ln(x_max)-ln(m_min))
function normalize_col(r, col)
	local min = 99990
	local max = 0
	for i=1, #r do
		for u=1, r[i]:size()[1] do
			--Clamp max dt to 4s
			if r[i][u][col] > 4000 then r[i][u][col] = 4000 end
			r[i][u][col] = math.log(r[i][u][col]+1)-- +1 to prevent ln(0)
			local val = r[i][u][col]
			if min > val then min = val end
			if max < val then max = val end
		end
	end

	for i=1, #r do
		for u=1, r[i]:size()[1] do
			r[i][u][col] = (r[i][u][col] - min)/(max - min)
		end
	end

	meta[col..'min'] = min
	meta[col..'max'] = max

	return r
end

function new_epoch()
	start_index = 1
	local prev_loss = loss
	loss = loss/batches
	local delta = loss-prev_loss

	local prev_valid = valid_loss

	model:evaluate()
	valid_loss = validate(model, opt.rho, opt.bs, opt.vd, criterion)
	model:training()

	local v_delta = valid_loss - prev_valid
	prev_valid = valid_loss_

	print(string.format("Ep %d loss=%.8f  dl=%.6e  valid=%.8f  dv=%.6e", curr_ep, loss, delta, valid_loss, v_delta))
	if logger then
		logger:add{curr_ep, loss, delta, valid_loss, v_delta}
	end

	curr_ep=curr_ep+1

	if(curr_ep % 10 == 0 and opt.o ~= '') then torch.save(opt.o, model) end --Autosave
	collectgarbage()
	loss = 0
	batches = 0
end

function next_batch()
	start_index = start_index + opt.bs

	batch = create_batch(start_index)
	if batch == -1 then
		new_epoch()
		batch = create_batch(start_index)
	end

	batches = batches + 1

	return batch
end

function feval(p)
	if params ~= p then
		params:copy(p)
	end

	batch = next_batch()
	local x = batch[1]
	local y = batch[2]

	gradparams:zero()
	local yhat = model:forward(x)
	local train_loss = criterion:forward(yhat, y)
	local e = torch.mean(torch.abs(yhat-y))
	loss = loss + e--Use real error instead of criterion
	model:backward(x, criterion:backward(yhat, y))

	collectgarbage()

	return train_loss, gradparams
end

function train()
	model:training()--Training mode
	math.randomseed(os.time())

	local optim_cfg = {learningRate=opt.lr, learningRateDecay=opt.lrd, weightDecay=opt.wd}
	local progress = -1

	for e=1, opt.ep do
		while curr_ep == start_ep+e do
			if progress ~= math.floor(100*(start_index/totlen)) then
				progress = math.floor(100*(start_index/totlen))
				xlua.progress(100*(e-1)+progress, 100*opt.ep)
			end

			optim.adagrad(feval, params, optim_cfg)
			collectgarbage()
		end
	end

	model:evaluate() --Exit training mode
end

function create_batch(start_index)
	local i = start_index
	local song = torch.Tensor()
	local songindex = 0
	--Select the correct song
	for k, s in pairs(data) do
		if s:size()[1] > i then
			song = s
			songindex = k
			break
		else
			i = i - s:size()[1]
		end
		if i < 1 then i = 1 end
	end
	--Create batch
	local x = torch.Tensor(opt.bs, opt.rho, DATA_WIDTH)
	local y = torch.Tensor(opt.bs, 1)

	--TODO Song is empty

	for u = 1, opt.bs do
		::s::
		if song:size()[1] < i+u+opt.rho+1 then
			song = data[songindex+1]
			if song==nil then return -1 end
			songindex = songindex+1
			i=1
			goto s
		end

		for o = opt.rho, 1, -1 do
			x[u][o] = song[i+o+u]
		end
		x[u][opt.rho][89] = 1 --We'll just set this to 1 for now
		y[u] = song[i+u+opt.rho][89]--Just the time as output
	end

	if opt.opencl then
		x = x:cl()
		y = y:cl()
	end

	return {x, y}
end

function create_time_model()
	local model = nn.Sequential()
	local rnn = nn.Sequential()

	local l = 1
	
	--Recurrent layer
	rnn:add(nn.FastLSTM(DATA_WIDTH, opt.hs[l], opt.rho))
	rnn:add(nn.SoftSign())
	for i=1, opt.rl-1 do
		l = l+1
		rnn:add(nn.FastLSTM(opt.hs[l-1], opt.hs[l], opt.rho))
		rnn:add(nn.SoftSign())
	end

	model:add(nn.SplitTable(1, 2))
	model:add(nn.Sequencer(rnn))
	model:add(nn.SelectTable(-1))
	--Dense layers
	for i=1, opt.dl do
		l = l+1
		model:add(nn.Linear(opt.hs[l-1], opt.hs[l]))
		model:add(nn.SoftSign())
	end
	--Output layer
	model:add(nn.Linear(opt.hs[l], 1))
	model:add(nn.ReLU())--Time can't be negative

	if opt.opencl then 
		return model:cl()
	else 
		return model 
	end
end

if lfs.attributes(opt.o) then--Resume training
	model = torch.load(opt.o)
	resume = true
	--Read JSON
	local file = assert(io.open(opt.o..".meta", 'r'))
	meta = json.decode(file:read('*all'))
	file:close()
	filename = opt.o
	ep = opt.ep

	--Copy table
	for key, val in pairs(meta) do
		opt[key] = val
	end

	opt.o = filename
	opt.ep = ep
	opt.datasize = 0

	print(opt)

	curr_ep = meta['ep']+1
	start_ep = meta['ep']
	opt.lr = meta['lr']/(1+meta['lrdecay']*meta['ep'])--Restore decayed lr
	meta['ep'] = meta['ep'] + opt.ep
	print("opt.ep:", opt.ep, "meta.ep", meta.ep)
	logger = optim.Logger(opt.o..".log2")
else
	model = create_time_model()
	
	if opt.o ~= '' then
		logger = optim.Logger(opt.o..".log")
		logger:setNames{'epoch', 'loss', 'delta', 'v_loss', 'v_delta'}
	else print("\n\n\nWARNING: No output file!\n\n\n") end --To prevent future mistakes
end

params, gradparams = model:getParameters()
criterion = nn.MSECriterion(true)
if opt.opencl then criterion:cl() end

data = create_dataset(opt.d, true, opt.ds)
data = normalize_col(data, 89)

if opt.datasize ~= 0 then
	local l = #data
	for i=opt.ds, l do
		data[i] = nil
	end
end

totlen = get_total_len(data)

print(curr_ep)
print(start_ep)

train()

if opt.o ~= '' then
	torch.save(opt.o, model)
	local file = assert(io.open(opt.o..".meta", 'w'))
	file:write(json.encode(meta))
	file:close()
	--Merge the logs
	if resume then os.execute("cat "..opt.o..".log2 >> "..opt.o..".log") end
end
