classdef Monster < matlab.mixin.Copyable
	% This class provides the main logic for a simulation
	% An instance of the class Monster has the following properties
	% 
	% :Config: (MonsterConfig) simulation config class instance
	% :Sites: (Array<Site>) simulation cell sites class instances
	% :Cells: (Array<EvolvedNodeB>) reference to network cells
	% :Users: (Array<UserEquipment>) simulation UEs class instances
	% :Channel: (Channel) simulation channel class instance
	% :Traffic: (TrafficGenerator) simulation traffic generator class instance

	properties 
		Config;
		Sites;
		Cells;
		Users;
		Channel;
		Traffic;
		Results;
		Logger;
	end

	methods 
		function obj = Monster(Config, Logger)
			% Monster constructor 
			%
			% :param Config: MonsterConfig instance
			% :param Logger: MonsterLog instance

			% Assert that the configuration is valid before starting the construction
			Config.assertConfig();

			obj.Logger = Logger;
			obj.Config = Config;
			obj.Logger.log('(MONSTER) setting up simulation', 'DBG');
			obj.setupSimulation();
			obj.Logger.log('(MONSTER) simulation setup completed', 'DBG');

			if obj.Config.SimulationPlot.runtimePlot
				% Draw the eNodeBs
				obj.Config.Plot.Layout.drawScenario(obj.Config, obj.Sites);
				% Draw the UEs
				obj.Config.Plot.Layout.drawUes(obj.Users, obj.Config, obj.Logger);
			end
		end

		function obj = setupSimulation(obj)
			% setupSimulation calls the initialisation functions for the simulation properties
			% 
			% :param obj: Monster instance
			% :returns obj: initialised Monster instance
			%

			% Create network layout
			obj.Logger.log('(MONSTER - setupSimulation) setting up network layout', 'DBG');
			obj.Config.setupNetworkLayout(obj.Logger);

			% Setup eNodeBs
			obj.Logger.log('(MONSTER - setupSimulation) setting up simulation sites', 'DBG');
			Sites = setupSites(obj.Config, obj.Logger);
			Cells = [Sites.Cells];

			% Setup UEs
			obj.Logger.log('(MONSTER - setupSimulation) setting up simulation UEs', 'DBG');
			Users = setupUsers(obj.Config, obj.Logger);

			% Setup channel
			obj.Logger.log('(MONSTER - setupSimulation) setting up simulation channel', 'DBG');
			Channel = setupChannel(Cells, Users, obj.Config, obj.Logger);

			% Setup traffic
			obj.Logger.log('(MONSTER - setupSimulation) setting up simulation traffic', 'DBG');
			[Traffic, Users] = setupTraffic(Users, obj.Config, obj.Logger);
            
      %Setup backhaul
      obj.Logger.log('(MONSTER - setupSimulation) setting up simulation backhaul','DBG');
      Traffic = applyBackhaulDelay(Traffic, obj.Config);

			% Setup results
			obj.Logger.log('(MONSTER - setupSimulation) setting up simulation metrics recorder', 'DBG');
			Results = setupResults(obj.Config, obj.Logger);

			% Assign the properties to the Monster object
			
			obj.Sites = Sites;
			obj.Cells = Cells;
			obj.Users = Users;
			obj.Channel = Channel;
			obj.Traffic = Traffic;
			obj.Results = Results;			
		end
		
		function obj = setupRound(obj, iRound)
			% setupRound configures the simulation runtime parameters prior the start of a round
			%
			% :obj: Monster instance
			% :iRound: Integer that represents the new simulation round
			%

			% Update Config property
			obj.Config.Runtime.currentRound = iRound;
			obj.Config.Runtime.currentTime = iRound*10e-3;  
			obj.Config.Runtime.remainingTime = (obj.Config.Runtime.totalRounds - obj.Config.Runtime.currentRound)*10e-3;
			obj.Config.Runtime.remainingRounds = obj.Config.Runtime.totalRounds - obj.Config.Runtime.currentRound - 1;
			% Update Channel property
			obj.Channel.setupRound(obj.Config.Runtime.currentRound, obj.Config.Runtime.currentTime);
		
		end

		function obj = run(obj)
			% run performs all the calls to methods needed for a single simulation round
			%
			% :obj: Monster instance
			%

			obj.Logger.log('(MONSTER - run) performing UE movement', 'DBG');
			obj.moveUsers();

			obj.Logger.log('(MONSTER - run) checking UE-eNodeB association', 'DBG');
			obj.associateUsers();

			obj.Logger.log('(MONSTER - run) updating UE transmission queues', 'DBG');
			obj.updateUsersQueues();

			obj.Logger.log('(MONSTER - run) downlink UE scheduling', 'DBG');
			obj.scheduleDL();

			obj.Logger.log('(MONSTER - run) creating TB, codewords and waveforms for downlink', 'DBG');
			obj.setupEnbTransmitters();

			obj.Logger.log('(MONSTER - run) traversing channel in downlink', 'DBG');
			obj.downlinkTraverse();

			obj.Logger.log('(MONSTER - run) downlink UE reception', 'DBG');
			obj.downlinkUeReception();

			obj.Logger.log('(MONSTER - run) downlink UE data decoding', 'DBG');
			obj.downlinkUeDataDecoding();
            
            obj.Logger.log('(MONSTER - run) plotting constellation diagrams and spectrums', 'DBG');
            obj.plotRuntime();
            
			obj.Logger.log('(MONSTER - run) uplink scheduling', 'DBG');
			obj.scheduleUL();

			obj.Logger.log('(MONSTER - run) setting up UE uplink', 'DBG');
			obj.setupUeTransmitters();
			
			obj.Logger.log('(MONSTER - run) traversing channel in uplink', 'DBG');
			obj.uplinkTraverse();

			obj.Logger.log('(MONSTER - run) uplink eNodeB reception', 'DBG');
			obj.uplinkEnbReception();

			% TODO: no data is actually being sent
			%obj.uplinkEnbDataDecoding();
		end

		function obj = collectResults(obj)
			% collectResults performs the collection and processing of a simulation round
			%
			% :obj: Monster instance
			%

			obj.Logger.log('(MONSTER - collectResults) eNodeB metrics recording', 'DBG');
			obj.Results = obj.Results.recordEnbMetrics(obj.Cells, obj.Config, obj.Logger);

			obj.Logger.log('(MONSTER - collectResults) UE metrics recording', 'DBG');
			obj.Results = obj.Results.recordUeMetrics(obj.Users, obj.Config.Runtime.currentRound, obj.Logger);

		end

		function obj = clean(obj)
			% clean performs a cleanup of the simulation data structures for the next round
			%
			% :obj: Monster instance
			%

			obj.Logger.log('(MONSTER - clean) eNodeB end of round cleaning', 'DBG');
			arrayfun(@(x)x.reset(obj.Config.Runtime.currentRound + 1), obj.Cells);

			obj.Logger.log('(MONSTER - clean) eNodeB end of round cleaning', 'DBG');
			arrayfun(@(x)x.reset(), obj.Users);		
		end
			

	end	

	methods 
		function obj = moveUsers(obj)
			% moveUsers performs UE movements at the beginning of each round
			%
			% :obj: Monster instanceo

			arrayfun(@(x)x.move(obj.Config.Runtime.currentRound), obj.Users);
		end

		function obj = associateUsers(obj)
			% associateUsers associates UEs to eNodeBs based on the association refresh timer
			%
			% :obj: Monster instance

			if mod(obj.Config.Runtime.currentTime, obj.Config.Scheduling.refreshAssociationTimer) == 0
				obj.Logger.log('(MONSTER - associateUsers) UEs-eNodeBs re-associating', 'DBG');
				refreshUsersAssociation(obj.Users, obj.Cells, obj.Channel, obj.Config);
			else
				obj.Logger.log('(MONSTER - associateUsers) UEs-eNodeBs not re-associated', 'DBG');
			end			
		end
		
		function obj = updateUsersQueues(obj)
			% updateUsersQueues is used to update the transmission queues for a UE based on the current simulation time
			% 
			% :obj: Monster instance
			for iUser = 1: obj.Config.Ue.number
				UeTrafficGenerator = obj.Traffic([obj.Traffic.Id] == obj.Users(iUser).Traffic.generatorId);
				obj.Users(iUser).Queue = UeTrafficGenerator.updateTransmissionQueue(obj.Users(iUser), obj.Config.Runtime.currentTime);
			end
		end

		function obj = scheduleDL(obj) 
			% scheduleDL is used to perform the allocation of eNodeB resources in the downlink to the UEs
			% 
			% :obj: Monster instance
			%
			
			% Set the ShouldSchedule flag for all the eNodeBs 
			arrayfun(@(x)x.evaluateScheduling(obj.Users), obj.Cells);

			% Now call the schedule method on the eNodeBs
			arrayfun(@(x)x.downlinkSchedule(obj.Users, obj.Config), obj.Cells);

			% Finally, evaluate the power state for the eNodeBs
			% TODO revise for multiple macro eNodeBs
			% arrayfun(@(x)x.evaluatePowerState(obj.Config, obj.Cells), obj.Cells)
		end

		function obj = scheduleUL(obj)
			% scheduleUL is used to perform the allocation of eNodeB resources in the uplink
			% 
			% :obj: Monster instance
			%


			% Use the result of refreshUsersAssociation to setup the UL scheduling
			arrayfun(@(x)x.resetScheduleUL(), obj.Cells);
			arrayfun(@(x)x.setScheduleUL(obj.Config), obj.Cells);

			for iUser = 1:length(obj.Users)
				iServingCell = find([obj.Cells.NCellID] == obj.Users(iUser).ENodeBID);
				obj.Users(iUser).setSchedulingSlots(obj.Cells(iServingCell));
			end

		end

		function obj = setupEnbTransmitters(obj)
			% setupEnbTransmitters is used to prepare the data for the downlink transmission
			% 
			% :obj: Monster instance
			%
			
			% Create the transport blocks for all the UEs
			arrayfun(@(x)x.generateTransportBlockDL(obj.Cells, obj.Config), obj.Users);

			% Create the codewords for all the UEs
			arrayfun(@(x)x.generateCodewordDL(), obj.Users);

			% Setup the reference signals at the eNB transmitters 
			arrayfun(@(x)x.setupGrid(obj.Config.Runtime.currentRound), [obj.Cells.Tx]);

			% Create the symbols for all the UEs' codewords at the eNodeBs
			arrayfun(@(x)x.setupPdsch(obj.Users), obj.Cells);

			% Finally modulate the waveform for all the eNodeBs
			arrayfun(@(x)x.modulateTxWaveform(), [obj.Cells.Tx]);

		end

		function obj = downlinkTraverse(obj)
			% donwlinkTraverse is used to perform a channel traversal in the downlink
			% 
			% :obj: Monster instance
			%
			obj.Channel.traverse(obj.Cells, obj.Users, 'downlink');

		end

		function obj = downlinkUeReception(obj)
			% donwlinkUeReception is used to perform the reception of the eNodeBs waveforms in downlink at the UEs
			% 
			% :obj: Monster instance
			%
			arrayfun(@(x)x.downlinkReception(obj.Cells, obj.Channel.Estimator.Downlink), obj.Users);

		end

		function obj = downlinkUeDataDecoding(obj)
			% downlinkUeDataDecoding is used to decode the data contained in the demodulated waveform
			% 
			% :obj: Monster instance
			%

			arrayfun(@(x)x.downlinkDataDecoding(obj.Config), obj.Users);
		end

		function obj = setupUeTransmitters(obj)
			% setupUeTransmitters is used to setup the UE transmitters for the uplink
			% 
			% :obj: Monster instance
			% 
			arrayfun(@(x)x.setupTransmission(), [obj.Users.Tx]);
		
		end

		function obj = uplinkTraverse(obj)
			% uplinkTraverse is used to perform a channel traversal in the uplink
			% 
			% :obj: Monster instance
			% 
			obj.Channel.traverse(obj.Cells, obj.Users,'uplink');
		
		end

		function obj = uplinkEnbReception(obj)
			% uplinkEnbReception performs the reception of the UEs waveforms in uplink at the eNodeBs
			% 
			% :obj: Monster instance
			%
			arrayfun(@(x)x.createReceivedSignal(), [obj.Cells.Rx]);
			arrayfun(@(x)x.uplinkReception(obj.Users, obj.Config.Runtime.currentTime, obj.Channel.Estimator), obj.Cells);			
		
		end 

		function obj = uplinkEnbDataDecoding(obj)
			% uplinkEnbDataDecoding performs the decoding of the data contained in the demodulated waveform
			%
			% :obj: Monster instance
			%
			arrayfun(@(x)x.uplinkDataDecoding(obj.Users, obj.Config), obj.Cells);
		
        end
        
        function obj = plotRuntime(obj)
           % plotRuntime executes the runtime plots
           %
           % :obj: Monster instance
           %
           if obj.Config.SimulationPlot.runtimePlot
               plotSpectrums(obj.Users, obj.Cells, obj.Config);
               plotConstDiagramDL(obj.Cells, obj.Users, obj.Config);
               %plotLinks(obj.Users, obj.Cells, obj.Config.Plot.LayoutAxes, 'downlink');
               plotAssociationTable(obj.Users, obj.Cells, obj.Config);
           end
        end
	end
end