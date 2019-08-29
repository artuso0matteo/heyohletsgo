classdef Monster3GPP38901 < matlab.mixin.Copyable
	% Monster3GPP38901 defines a class for the 3GPP channel model specified in 38.901
	%
	% :CellConfigs:
	% :Channel:
	% :TempSignalVariables:
	% :Pairings:
	% :LinkConditions:
	%
	
	properties
		CellConfigs;
		Channel;
		TempSignalVariables = struct();
		Pairings = [];
		LinkConditions = struct();
	end
	
	methods
		function obj = Monster3GPP38901(MonsterChannel, Cells)
			obj.Channel = MonsterChannel;
			obj.setupCellConfigs(Cells);
			obj.createSpatialMaps();
			obj.LinkConditions.downlink = [];
			obj.LinkConditions.uplink = [];
		end
		
		function setupCellConfigs(obj, Cells)
			% Setup structure for Cell configs
			%
			% :obj:
			% :Cells
			%
			
			for iCell = 1:length(Cells)
				Cell = Cells(iCell);
				cellString = sprintf('Cell%i',Cell.NCellID);
				obj.CellConfigs.(cellString) = struct();
				obj.CellConfigs.(cellString).Tx = Cell.Tx;
				obj.CellConfigs.(cellString).Position = Cell.Position;
				obj.CellConfigs.(cellString).Seed = Cell.Seed;
				obj.CellConfigs.(cellString).LSP = lsp3gpp38901(obj.Channel.getAreaType(Cell));
			end
		end
		
		function propagateWaveforms(obj, Cells, Users, Mode)
			% propagateWaveforms
			%
			% :onj:
			%	:Cells:
			% :Users:
			% :Mode:
			%
			
			Pairing = obj.Channel.getPairing(Cells, Mode);
			obj.Pairings = Pairing;
			numLinks = length(Pairing(1,:));
			
			obj.LinkConditions.(Mode) = cell(numLinks,1);
			
			for i = 1:numLinks
				obj.clearTempVariables()
				% Local copy for mutation
				Cell = Cells([Cells.NCellID] == Pairing(1,i));
				user = Users(find([Users.NCellID] == Pairing(2,i))); %#ok
				
				% Set waveform to be manipulated
				switch Mode
					case 'downlink'
						obj.setWaveform(Cell)
					case 'uplink'
						obj.setWaveform(user)
				end
				
				% Calculate recieved power between Cell and user
				[receivedPower, receivedPowerWatt] = obj.computeLinkBudget(Cell, user, Mode);
				obj.TempSignalVariables.RxPower = receivedPower;
				
				% Calculate SNR using thermal noise
				[SNR, SNRdB, noisePower] = obj.computeSNR();
				obj.TempSignalVariables.RxSNR = SNR;
				obj.TempSignalVariables.RxSNRdB = SNRdB;
				
				% Add/compute interference
				SINR = obj.computeSINR(Cell, user, Cells, receivedPowerWatt, noisePower, Mode);
				obj.TempSignalVariables.RxSINR = SINR;
				obj.TempSignalVariables.RxSINRdB = 10*log10(SINR);
				
				% Compute N0
				N0 = obj.computeSpectralNoiseDensity(Cell, Mode);
				
				% Add AWGN
				noise = N0*complex(randn(size(obj.TempSignalVariables.RxWaveform)), randn(size(obj.TempSignalVariables.RxWaveform)));
				rxSig = obj.TempSignalVariables.RxWaveform + noise;
				obj.TempSignalVariables.RxWaveform = rxSig;
				
				% Add fading
				if obj.Channel.enableFading
					obj.addFading(Cell, user, Mode);
				end
				
				% Receive signal at Rx module
				switch Mode
					case 'downlink'
						obj.setReceivedSignal(user);
					case 'uplink'
						obj.setReceivedSignal(Cell, user);
				end
				
				% Store in channel variable
				obj.storeLinkCondition(i, Mode)
				
			end
		end
		
		function N0 = computeSpectralNoiseDensity(obj, Cell, Mode)
			% Compute spectral noise density NO
			%
			% :param obj:
			% :param Cell:
			% :param Mode:
			% :returns N0:
			%
			% TODO: Find citation for this computation. It's partly taken from matworks - however there is a theoretical equation for the symbol energy of OFDM signals.
			%
			
			switch Mode
				case 'downlink'
					Es = sqrt(2.0*Cell.CellRefP*double(obj.TempSignalVariables.RxWaveformInfo.Nfft));
					N0 = 1/(Es*sqrt(obj.TempSignalVariables.RxSINR));
				case 'uplink'
					N0 = 1/(sqrt(obj.TempSignalVariables.RxSINR)  * sqrt(double(obj.TempSignalVariables.RxWaveformInfo.Nfft)))/sqrt(2);
			end
			
		end
		
		function [SNR, SNRdB, thermalNoise] = computeSNR(obj)
			% Calculate SNR using thermal noise. Thermal noise is bandwidth dependent.
			%
			% :param obj:
			% :returns SNR:
			% :returns SNRdB:
			% :returns thermalNoise:
			%
			
			[thermalLossdBm, thermalNoise] = thermalLoss(obj.TempSignalVariables.RxWaveform, obj.TempSignalVariables.RxWaveformInfo.SamplingRate);
			rxNoiseFloor = thermalLossdBm;
			SNRdB = obj.TempSignalVariables.RxPower-rxNoiseFloor;
			SNR = 10.^((SNRdB)./10);
		end
		
		
		function receivedPower = getreceivedPowerMatrix(obj, Cell, user, sampleGrid)
			% Used for obtaining a SINR estimation of a given position
			%
			% :param obj:
			% :param Cell:
			% :param user:
			% :param sampleGrid:
			% :returns receivedPower:
			%
			
			obj.TempSignalVariables.RxWaveform = Cell.Tx.Waveform; % Temp variable for BW indication
			obj.TempSignalVariables.RxWaveformInfo = Cell.Tx.WaveformInfo; % Temp variable for BW indication
			[receivedPower, receivedPowerWatt] = obj.computeLinkBudget(Cell, user, 'downlink', sampleGrid);
			receivedPower = reshape(receivedPower, length(sampleGrid), []);
			obj.clearTempVariables();
		end
		
		function [SINR] = computeSINR(obj, Cell, user, Cells, receivedPowerWatt, noisePower, Mode)
			% Compute SINR using received power and the noise power.
			% Interference is given as the power of the received signal, given the power of the associated Cell, over the power of the neighboring cells.
			%
			% :param obj:
			% :param Cell:
			% :param user:
			% :param Cells:
			% :param receivedPowerWatt:
			% :param noisePower:
			% :param Mode:
			% :returns SINR:
			%
			% v1. InterferenceType Full assumes full power, thus the SINR computation can be done using just the link budget.
			% TODO: Add waveform type interference.
			% TODO: clean up function arguments.
			%
			
			if strcmp(obj.Channel.InterferenceType,'Full')
				interferingCells = obj.Channel.getInterferingCells(Cell, Cells);
				listCellPower = obj.listCellPower(user, interferingCells, Mode);
				
				intCells  = fieldnames(listCellPower);
				intPower = 0;
				% Sum power from interfering cells
				for intCell = 1:length(fieldnames(listCellPower))
					intPower = intPower + listCellPower.(intCells{intCell}).receivedPowerWatt;
				end
				
				SINR = obj.Channel.calculateSINR(receivedPowerWatt, intPower, noisePower);
			else
				SINR = obj.TempSignalVariables.RxSNR;
			end
		end
		
		function SINR = listSINR(obj, User, Cells, Mode)
			% Get list of SINR for all cells, assuming they all interfere.
			% TODO: Find interfering cells based on class
			%
			% :param User: One user
			% :param Cells: Multiple eNB's
			% :param Mode: Mode of transmission.
			% :returns SINR: List of SINR for each Cell
			
			obj.Channel.Logger.log('func listSINR: Interference is considered intra-class eNB cells','WRN')
			
			
			% Get received power for each Cell
			for iCell = 1:length(Cells)
				Cell = Cells(iCell);
				[~, receivedPower(iCell)] = obj.computeLinkBudget(Cell, User, Mode);
			end
			
			% Compute SINR from each Cell
			for iCell = 1:length(Cells)
				Cell = Cells(iCell);
				cellPower = receivedPower(iCell);
				interferingPower = sum(receivedPower(1:end ~= iCell));
				[~, thermalNoise] = thermalLoss();
				SINR(iCell) = 10*log10(obj.Channel.calculateSINR(cellPower, interferingPower, thermalNoise));
			end
			
		end
		
		function list = listCellPower(obj, User, Cells, Mode)
			% Get list of recieved power from all cells
			%
			% :param obj:
			% :param User:
			% :param Cells:
			% :param Mode:
			% :returns list:
			%
			
			list = struct();
			for iCell = 1:length(Cells)
				Cell = Cells(iCell);
				cellStr = sprintf('CellNCellID%i',Cell.NCellID);
				list.(cellStr).receivedPowerdBm = obj.computeLinkBudget(Cell, User, Mode);
				list.(cellStr).receivedPowerWatt = 10^((list.(cellStr).receivedPowerdBm-30)/10);
				list.(cellStr).NCellID = Cell.NCellID;
			end
			
		end

		function [txConfig, userConfig] = getLinkParameters(obj, Cell, User, mode, varargin)
			% Function acts like a wrapper between lower layer physical computations (usually matrix operations) and the Monster API of Cell and User objects
			% construct a structure for handling variables
			%
			% :param Cell: Cell object
			% :param User: User object
			% :param mode: 'downlink' or 'uplink' % Currently only difference is frequency
			% :param varargin: (optional) 2xN array of positions for which the link budget is wanted.
			userConfig = struct();
			txConfig = struct();
			
			txConfig.position = Cell.Position;

			if ~isempty(varargin{1})
				[X, Y] = meshgrid(varargin{1}{1}(1,:), varargin{1}{1}(2,:));
				Z = User.Position(3)*ones(length(X),length(Y));
			else
				X = User.Position(1);
				Y = User.Position(2);
				Z = User.Position(3);
			end
			userConfig.positions = [reshape(X,[],1)  reshape(Y,[],1) reshape(Z,[],1)];
			
			userConfig.Indoor = User.Mobility.Indoor;
						
			userConfig.d2d = arrayfun(@(x, y) obj.Channel.getDistance(Cell.Position(1:2),[x y]), userConfig.positions(:,1), userConfig.positions(:,2));
			userConfig.d3d = arrayfun(@(x, y, z) obj.Channel.getDistance(Cell.Position(1:3),[x y z]), userConfig.positions(:,1), userConfig.positions(:,2), userConfig.positions(:,3));
			switch mode
				case 'downlink'
					txConfig.hBs = Cell.Position(3);
					txConfig.areaType = obj.Channel.getAreaType(Cell);
					txConfig.seed = obj.Channel.getLinkSeed(User, Cell);
					txConfig.freq = Cell.Tx.Freq;
					userConfig.hUt = User.Position(3);
					
					
				case 'uplink'
					txConfig.hBs = Cell.Position(3);
					txConfig.areaType = obj.Channel.getAreaType(Cell);
					txConfig.seed = obj.Channel.getLinkSeed(User, Cell);
					txConfig.freq = User.Tx.Freq;
					userConfig.hUt = User.Position(3);
			end

		end
	

		function [userConfig] = computeLOS(obj, Cell, txConfig, userConfig)
			% Compute LOS situation
			% If a probability based LOS method is used, the LOSprop is realized with spatial consistency

			if userConfig.Indoor
				userConfig.LOS = 0;
				userConfig.LOSprop = NaN;
			else
				[userConfig.LOS, userConfig.LOSprop] = obj.Channel.isLinkLOS(txConfig, userConfig, false);
				if ~isnan(userConfig.LOSprop) % If a probablistic LOS model is used, the LOS state needs to be realized with spatial consistency
					userConfig.LOS = obj.spatialLOSstate(Cell, userConfig.positions(:,1:2), userConfig.LOSprop);
				end
			end
		end

		function [receivedPower, receivedPowerWatt] = computeLinkBudget(obj, Cell, User, mode, varargin)
			% Compute link budget for Tx -> Rx
			%
			% :param obj:
			% :param Cell:
			% :param User:
			% :param mode:
			% :returns receivedPower:
			% :returns receivedPowerWatt:
			%
			% This requires a :meth:`computePathLoss` method, which is supplied by child classes.
			% returns updated RxPwdBm of RxNode.Rx
			% The channel is reciprocal in terms of received power, thus the path
			% loss is extracted from channel conditions provided by
			%
			

			[txConfig, userConfig] = obj.getLinkParameters(Cell, User, mode, varargin);
			
			userConfig = obj.computeLOS(Cell, txConfig, userConfig);
		
			if obj.Channel.enableShadowing
				xCorr = arrayfun(@(x,y,z) obj.computeShadowingLoss(Cell, [x y], z), reshape(userConfig.positions(:,1),size(userConfig.LOS)), reshape(userConfig.positions(:,2),size(userConfig.LOS)), userConfig.LOS );
			else
				xCorr = 0;
			end

			if userConfig.Indoor
				indoorLoss = obj.computeIndoorLoss(txConfig, userConfig);
			else
				indoorLoss = 0;
			end

			
			EIRPdBm = arrayfun(@(x,y, z) Cell.Tx.getEIRPdBm(Cell.Position, [x y z]), userConfig.positions(:,1), userConfig.positions(:,2), userConfig.positions(:,3));
			lossdB = obj.computePathLoss(txConfig, userConfig);
			
			% Add possible shadowing loss and indoor loss
			lossdB = lossdB + xCorr + indoorLoss;
			
			switch mode
				case 'downlink'
					DownlinkUeLoss = arrayfun(@(x,y) User.Rx.getLoss(Cell.Position, [x y]), userConfig.positions(:,1), userConfig.positions(:,2));
					receivedPower = EIRPdBm-lossdB+DownlinkUeLoss; %dBm
				case 'uplink'
					EIRPdBm = User.Tx.getEIRPdBm;
					receivedPower = EIRPdBm-lossdB-Cell.Rx.NoiseFigure; %dBm 
			end
			
			receivedPowerWatt = 10.^((receivedPower-30)./10);
		end
		
		
		function [indoorLoss] = computeIndoorLoss(txConfig, userConfig)
			
			% Low loss model consists of LOS
			materials = {'StandardGlass', 'Concrete'; 0.3, 0.7};
			sigma_P = 4.4;
			
			% High loss model consists of
			%materials = {'IIRGlass', 'Concrete'; 0.7, 0.3}
			%sigma_P = 6.5;
			
			PL_tw = buildingloss3gpp38901(materials, txConfig.freq/10e2);
			
			% If indoor depth can be computed
			%PL_in = indoorloss3gpp38901('', 2d_in);
			% Otherwise sample from uniform
			PL_in  = indoorloss3gpp38901(userConfig.areaType);
			indoorLoss = PL_tw + PL_in + randn(1, 1)*sigma_P;
			
			
		end
		
		function [lossdB] = computePathLoss(obj, txConfig, userConfig)
			% Computes path loss. uses the following parameters
			% TODO revise function documentation format
			% ..todo:: Compute indoor depth from mobility class
			%
			% * `f` - Frequency in GHz
			% * `hBs` - Height of Tx
			% * `hUt` - height of Rx
			% * `d2d` - Distance in 2D
			% * `d3d` - Distance in 3D
			% * `LOS` - Link LOS boolean, determined by :meth:`ch.SonohiChannel.isLinkLOS`
			% * `shadowing` - Boolean for enabling/disabling shadowing using log-normal distribution
			% * `avgBuilding` - Average height of buildings
			% * `avgStreetWidth` - Average width of the streets
			% * `varargin` -matrix forms of distance 2D, 3D and grid of positions
			
			% Extract transmitter configurations. All scalar values.
			hBs = txConfig.hBs;
			freq = txConfig.freq/10e2; % Convert to GHz
			areaType = txConfig.areaType;
			
			% Extract receiver configuration, can be arrays.
			hUt = userConfig.hUt;
			distance2d = userConfig.d2d;
			distance3d = userConfig.d3d;
			LOS = userConfig.LOS;
			
			% Check whether we have buildings in the scenario
			if ~isempty(obj.Channel.BuildingFootprints)
				avgBuilding = mean(obj.Channel.BuildingFootprints(:,5));
				avgStreetWidth = obj.Channel.BuildingFootprints(2,2)-obj.Channel.BuildingFootprints(1,4);
			else
				avgBuilding = 0;
				avgStreetWidth = 0;
			end
			
			try
				lossdB = loss3gpp38901(areaType, distance2d, distance3d, freq, hBs, hUt, avgBuilding, avgStreetWidth, LOS);
			catch ME
				if strcmp(ME.identifier,'Pathloss3GPP:Range')
						minRange = 10;
		 				lossdB = loss3gpp38901(areaType, minRange, distance3d, freq, hBs, hUt, avgBuilding, avgStreetWidth, LOS);
				else
					obj.Channel.Logger.log('Pathloss computation error', 'ERR')
				end
			end
			
		end
		
		
		function addFading(obj, Cell, user, mode)
			% addFading
			%
			% :param obj:
			% :param Cell:
			% :param user:
			% :param mode:
			%
			% TODO: Add possibility to change the fading model used from parameters.
			%
			
			fadingmodel = 'tdl';
			% UT velocity in km/h
			v = user.Mobility.Velocity * 3.6;
			
			% Determine channel randomness/correlation
			if obj.Channel.enableReciprocity
				seed = obj.Channel.getLinkSeed(user, Cell);
			else
				switch mode
					case 'downlink'
						seed = obj.Channel.getLinkSeed(user, Cell)+2;
					case 'uplink'
						seed = obj.Channel.getLinkSeed(user, Cell)+3;
				end
			end
			
			% Extract carrier frequncy and sampling rate
			switch mode
				case 'downlink'
					fc = Cell.Tx.Freq*10e5;          % carrier frequency in Hz
					samplingRate = Cell.Tx.WaveformInfo.SamplingRate;
				case 'uplink'
					fc = user.Tx.Freq*10e5;          % carrier frequency in Hz
					samplingRate = user.Tx.WaveformInfo.SamplingRate;
			end
			
			c = physconst('lightspeed'); % speed of light in m/s
			fd = (v*1000/3600)/c*fc;     % UT max Doppler frequency in Hz
			sig = [obj.TempSignalVariables.RxWaveform;zeros(200,1)];
			
			switch fadingmodel
				case 'cdl'
					cdl = nrCDLChannel;
					cdl.DelayProfile = 'CDL-C';
					cdl.DelaySpread = 300e-9;
					cdl.CarrierFrequency = fc;
					cdl.MaximumDopplerShift = fd;
					cdl.SampleRate = TxNode.Tx.WaveformInfo.SamplingRate;
					cdl.InitialTime = obj.Channel.simulationTime;
					cdl.TransmitAntennaArray.Size = [1 1 1 1 1];
					cdl.ReceiveAntennaArray.Size = [1 1 1 1 1];
					cdl.SampleDensity = 256;
					cdl.Seed = seed;
					obj.TempSignalVariables.RxWaveform = cdl(sig);
				case 'tdl'
					tdl = nrTDLChannel;
					
					% Set transmission direction for MIMO correlation
					switch mode
						case 'downlink'
							tdl.TransmissionDirection = 'Downlink';
						case 'uplink'
							tdl.TransmissionDirection = 'Uplink';
					end
					% TODO: Add MIMO to fading channel
					tdl.DelayProfile = 'TDL-E';
					tdl.DelaySpread = 300e-9;
					%tdl.MaximumDopplerShift = 0;
					tdl.MaximumDopplerShift = fd;
					tdl.SampleRate = samplingRate;
					tdl.InitialTime = obj.Channel.simulationTime;
					tdl.NumTransmitAntennas = 1;
					tdl.NumReceiveAntennas = 1;
					tdl.Seed = seed;
					%tdl.KFactorScaling = true;
					%tdl.KFactor = 3;
					[obj.TempSignalVariables.RxWaveform, obj.TempSignalVariables.RxPathGains, ~] = tdl(sig);
					obj.TempSignalVariables.RxPathFilters = getPathFilters(tdl);
			end
		end
		
		%%% UTILITY FUNCTIONS
		function config = findCellConfig(obj, Cell)
			% findCellConfig finds the Cell config
			%
			% :param obj:
			% :param Cell:
			% :returns config:
			%
			
			cellString = sprintf('Cell%i',Cell.NCellID);
			config = obj.CellConfigs.(cellString);
		end
		
		function h = getImpulseResponse(obj, Mode, Cell, User)
			% Plotting of impulse response applied from TxNode to RxNode
			%
			% :param obj:
			% :param Mode:
			% :param Cell:
			% :param user:
			% :returns h:
			%
			
			% Find pairing
			
			% Find stored pathfilters
			
			% return plot of impulseresponse
			h = sum(obj.TempSignalVariables.RxPathFilters,2);
		end
		
		function h = getPathGains(obj)
			% getPathGains
			%
			% :param obj:
			% :returns h:
			%
			
			h = sum(obj.TempSignalVariables.RxPathGains,2);
		end
		
		function setWaveform(obj, TxNode)
			% Copies waveform and waveform info from tx module to temp variables
			%
			% :param obj:
			% :param TxNode:
			%
			
			if isempty(TxNode.Tx.Waveform)
				obj.Channel.Logger.log('Transmitter waveform is empty.', 'ERR', 'MonsterChannel:EmptyTxWaveform')
			end
			
			if isempty(TxNode.Tx.WaveformInfo)
				obj.Channel.Logger.log('Transmitter waveform info is empty.', 'ERR', 'MonsterChannel:EmptyTxWaveformInfo')
			end
			
			obj.TempSignalVariables.RxWaveform = TxNode.Tx.Waveform;
			obj.TempSignalVariables.RxWaveformInfo =  TxNode.Tx.WaveformInfo;
		end
		
		function h = plotSFMap(obj, Cell)
			% plotSFMap
			%
			% :param obj:
			% :param Cell:
			% :returns h:
			%
			
			config = obj.findCellConfig(Cell);
			h = figure;
			contourf(config.SpatialMaps.axisLOS(1,:), config.SpatialMaps.axisLOS(2,:), config.SpatialMaps.LOS)
			hold on
			plot(config.Position(1),config.Position(2),'o', 'MarkerSize', 20, 'MarkerFaceColor', 'auto')
			xlabel('x [Meters]')
			ylabel('y [Meters]')
		end
		
		function RxNode = setReceivedSignal(obj, RxNode, varargin)
			% Copies waveform and waveform info to Rx module, enables transmission.
			% Based on the class of RxNode, uplink or downlink can be determined
			%
			% :param obj:
			% :param RxNode:
			% :param varargin:
			% :returns RxNode:
			%
			
			if isa(RxNode, 'EvolvedNodeB')
				userId = varargin{1}.NCellID;
				RxNode.Rx.createRecievedSignalStruct(userId);
				RxNode.Rx.ReceivedSignals{userId}.Waveform = obj.TempSignalVariables.RxWaveform;
				RxNode.Rx.ReceivedSignals{userId}.WaveformInfo = obj.TempSignalVariables.RxWaveformInfo;
				RxNode.Rx.ReceivedSignals{userId}.RxPwdBm = obj.TempSignalVariables.RxPower;
				RxNode.Rx.ReceivedSignals{userId}.SNR = obj.TempSignalVariables.RxSNR;
				RxNode.Rx.ReceivedSignals{userId}.PathGains = obj.TempSignalVariables.RxPathGains;
				RxNode.Rx.ReceivedSignals{userId}.PathFilters = obj.TempSignalVariables.RxPathFilters;
			elseif isa(RxNode, 'UserEquipment')
				RxNode.Rx.Waveform = obj.TempSignalVariables.RxWaveform;
				RxNode.Rx.WaveformInfo =  obj.TempSignalVariables.RxWaveformInfo;
				RxNode.Rx.RxPwdBm = obj.TempSignalVariables.RxPower;
				RxNode.Rx.SNR = obj.TempSignalVariables.RxSNR;
				RxNode.Rx.SINR = obj.TempSignalVariables.RxSINR;
				RxNode.Rx.PathGains = obj.TempSignalVariables.RxPathGains;
				RxNode.Rx.PathFilters = obj.TempSignalVariables.RxPathFilters;
			end
		end
		
		function storeLinkCondition(obj, index, mode)
			% storeLinkCondition
			%
			% :param obj:
			% :param index:
			% :param mode:
			%
			
			linkCondition = struct();
			linkCondition.Waveform = obj.TempSignalVariables.RxWaveform;
			linkCondition.WaveformInfo =  obj.TempSignalVariables.RxWaveformInfo;
			linkCondition.RxPwdBm = obj.TempSignalVariables.RxPower;
			linkCondition.SNR = obj.TempSignalVariables.RxSNR;
			linkCondition.SINR = obj.TempSignalVariables.RxSINR;
			linkCondition.PathGains = obj.TempSignalVariables.RxPathGains;
			linkCondition.PathFilters = obj.TempSignalVariables.RxPathFilters;
			obj.LinkConditions.(mode){index} = linkCondition;
		end
		
		function clearTempVariables(obj)
			% Clear temporary variables. These are used for waveform manipulation and power tracking
			% The property TempSignalVariables is used, and is a struct of several parameters.
			%
			% :param obj:
			%
			
			obj.TempSignalVariables.RxPower = [];
			obj.TempSignalVariables.RxSNR = [];
			obj.TempSignalVariables.RxSINR = [];
			obj.TempSignalVariables.RxWaveform = [];
			obj.TempSignalVariables.RxWaveformInfo = [];
			obj.TempSignalVariables.RxPathGains = [];
			obj.TempSignalVariables.RxPathFilters = [];
		end
	end
	
	methods (Access = private)
		
		function createSpatialMaps(obj)
			% createSpatialMaps
			%
			% :param obj:
			%
			
			% Construct structure for containing spatial maps
			cellStrings = fieldnames(obj.CellConfigs);
			for iCell = 1:length(cellStrings)
				config = obj.CellConfigs.(cellStrings{iCell});
				spatialMap = struct();
				fMHz = config.Tx.Freq;  % Freqency in MHz
				radius = obj.Channel.getAreaSize(); % Get range of grid
				
				if obj.Channel.enableShadowing
					% Spatial correlation map of LOS Large-scale SF
					[mapLOS, xaxis, yaxis] = obj.spatialCorrMap(config.LSP.sigmaSFLOS, config.LSP.dCorrLOS, fMHz, radius, config.Seed, 'gaussian');
					axisLOS = [xaxis; yaxis];
					
					% Spatial correlation map of NLOS Large-scale SF
					[mapNLOS, xaxis, yaxis] = obj.spatialCorrMap(config.LSP.sigmaSFNLOS, config.LSP.dCorrNLOS, fMHz, radius, config.Seed, 'gaussian');
					axisNLOS = [xaxis; yaxis];
					spatialMap.LOS = mapLOS;
					spatialMap.axisLOS = axisLOS;
					spatialMap.NLOS = mapNLOS;
					spatialMap.axisNLOS = axisNLOS;
				end
				
				% Configure LOS probability map G, with correlation distance
				% according to 7.6-18.
				[mapLOSprop, xaxis, yaxis] = obj.spatialCorrMap([], config.LSP.dCorrLOSprop, fMHz, radius,  config.Seed, 'uniform');
				axisLOSprop = [xaxis; yaxis];
				
				spatialMap.LOSprop = mapLOSprop;
				spatialMap.axisLOSprop = axisLOSprop;
				
				obj.CellConfigs.(cellStrings{iCell}).SpatialMaps = spatialMap;
			end
		end
		
		function LOS = spatialLOSstate(obj, Cell, userPosition, LOSprop)
			% Determine spatial LOS state by realizing random variable from
			% spatial correlated map and comparing to LOS probability. Done
			% according to 7.6.3.3
			%
			% :param obj:
			% :param Cell:
			% :param userPosition:
			% :param LOSprop:
			% :returns LOS:
			%
			
			config = obj.findCellConfig(Cell);
			map = config.SpatialMaps.LOSprop;
			axisXY = config.SpatialMaps.axisLOSprop;
			if length(LOSprop) >1
				LOSrealize = interp2(axisXY(1,:), axisXY(2,:), map, userPosition(:,1), userPosition(:,2), 'spline');
				LOSrealize = reshape(LOSrealize, size(LOSprop));
			else
				LOSrealize = interp2(axisXY(1,:), axisXY(2,:), map, userPosition(1), userPosition(2), 'spline');
			end
			LOS = LOSprop;
			LOS(LOSprop > LOSrealize) = 1;
			LOS(LOSprop < LOSrealize) = 0;
			%if LOSrealize < LOSprop
			%	LOS = 1;
			%else
			%	LOS = 0;
			%end
			
		end
		
		function XCorr = computeShadowingLoss(obj, Cell, userPosition, LOS)
			% Interpolation between the random variables initialized
			% provides the magnitude of shadow fading given the LOS state.
			%
			% .. todo:: Compute this using the cholesky decomposition as explained in the WINNER II documents of all LSP.
			%
			% :param obj:
			% :param Cell:
			% :param userPosition:
			% :param LOS:
			% :returns XCorr:
			%
			
			config = obj.findCellConfig(Cell);
			if LOS
				map = config.SpatialMaps.LOS;
				axisXY = config.SpatialMaps.axisLOS;
			else
				map = config.SpatialMaps.NLOS;
				axisXY = config.SpatialMaps.axisNLOS;
			end
			
			obj.checkInterpolationRange(axisXY, userPosition, obj.Channel.Logger);
			XCorr = interp2(axisXY(1,:), axisXY(2,:), map, userPosition(1), userPosition(2), 'spline');
			
			
		end
		
		
	end
	
	methods (Static)
		function [map, xaxis, yaxis] = spatialCorrMap(sigmaSF, dCorr, fMHz, radius, seed, distribution)
			% Create a map of independent Gaussian random variables according to the decorrelation distance.
			% Interpolation between the random variables can be used to realize the 2D correlations.
			%
			% :param sigmaSF:
			% :param dCorr:
			% :param fMHz:
			% :param radius:
			% :param seed:
			% :param distribution:
			% :returns map:
			% :returns xaxis:
			% :returns yaxis:
			%
			
			lambdac=300/fMHz;   % wavelength in m
			interprate=round(dCorr/lambdac);
			Lcorr=lambdac*interprate;
			Nsamples=round(radius/Lcorr);
			rng(seed);
			switch distribution
				case 'gaussian'
					map = randn(2*Nsamples,2*Nsamples)*sigmaSF;
				case 'uniform'
					map = rand(2*Nsamples,2*Nsamples);
			end
			xaxis=[-Nsamples:Nsamples-1]*Lcorr;
			yaxis=[-Nsamples:Nsamples-1]*Lcorr;
		end
		
		
		function checkInterpolationRange(axisXY, Position, Logger)
			% Function used to check if the position can be interpolated
			%
			% :param axisXY:
			% :param Position:
			%
			
			extrapolation = false;
			if Position(1) > max(axisXY(1,:))
				extrapolation = true;
			elseif Position(1) < min(axisXY(1,:))
				extrapolation = true;
			elseif Position(2) > max(axisXY(2,:))
				extrapolation = true;
			elseif Position(2) < min(axisXY(2,:))
				extrapolation = true;
			end
			
			if extrapolation
				pos = sprintf('(%s)',num2str(Position));
				bound = sprintf('(%s)',num2str([min(axisXY(1,:)), min(axisXY(2,:)), max(axisXY(1,:)), max(axisXY(2,:))]));
				Logger.log(sprintf('Position of Rx out of bounds. Bounded by %s, position was %s. Increase Channel.getAreaSize',bound,pos), 'ERR')
			end
		end
		
		function [LOS, prop] = LOSprobability(txConfig, userConfig)
			% LOS probability using table 7.4.2-1 of 3GPP TR 38.901
			%
			% :param txConfig:
			% :param userConfig:
			% :returns LOS: LOS boolean
			% :returns prop: Probability
			%
			prop = losProb3gpp38901(txConfig.areaType, userConfig.d2d, userConfig.hUt);
			
			% Realize probability
			x = rand(length(prop(:,1)),length(prop(1,:)));
			LOS = prop;
			LOS(x>LOS) = 0;
			LOS(LOS~= 0) =1;
			
		end
		
		
	end
end