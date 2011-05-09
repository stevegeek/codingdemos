classdef encoder < handle
%JPEG.ENCODER Implementation of a JPEG encoder body
%
%   +JPEG/encoder.m
%   Part of 'MATLAB Image & Video Compression Demos'
%
%   JPEG.encoder main properties:
%    * verbose (r/w): boolean to set state of verbose output to console
%    * input (r/w): the input image data. This parameter has a setter
%    method that determines the type of the data set to it to perform the
%    appropriate action. Can be set to a string filename, an image matrix
%    or a subsampled image structure.
%    * qualityFactor (r/w): an integer in the range 0-100 indicating the
%    quality of the JPEG to create, as per the IJG's JPEG implementation
%    * chromaSamplingMode (r/w): a string indicating the subsampling mode,
%    e.g. '4:2:0'
%    * output (r): the output data bitstream
%    * reconstruction (r): if 'doReconstruction' is true then this is set
%    to the YCbCr subsampled image structure of the reconstructed inverse
%    quantised/transformed data.
%
%   JPEG.encoder public methods:
%    * encoder(source): Constructor takes optional source filename
%    * encode(parameters): Actual encode procedure, returns a logical or
%    numeric array of the output bitstream.
%    * encodeToFile(filename, parameters): Actual encode procedure with
%    specific output file for bitstream. Returns boolean to indicate
%    success.
%
%   Example commands:
%       obj = JPEG.encoder('exampleImages/lena_color_256.bmp','DoEntropyCoding', false, 'DoReconstruction', true, 'Verbose', true);
%       bits = obj.encode();
%
%   Licensed under the 3-clause BSD license, see 'License.m'
%   Copyright (c) 2011, Stephen Ierodiaconou, University of Bristol.
%   All rights reserved.

    properties (SetObservable, SetAccess='protected')
        input

        qualityFactor
        chromaSamplingMode

        % If true the encoder will generate extra state to create a
        % reconstruction of the image with the given coding parameters up
        % to entropy coding.
        doReconstruction

        % If 'runLengthCoding' true encoder will do the zero run-length
        % coding procedure. If 'reOrderingCoefficients' is true then the
        % encoder will reorder the coefficients into zigzags. If
        % 'differentialDC' is true then the encoder will make the DC
        % coefficient differentials. If 'entropyCoding' is true then the
        % entropy coding will be performed, else the encoding process will
        % stop before
        isEnabledStage

        % Use MATLAB built-in or toolbox methods of lib/ versions
        useBuiltInMethods

        verbose

        imageMatrix
        imageStruct

        basisCoefficientMap
        luminanceScaledQuantisationTable
        chromaScaledQuantisationTable

        % Getters for these to parse data into format that is more readable
        % ???????
        coefficients
        quantisedCoefficients
        orderedCoefficients
        zerosRunLengthCodedOrderedACCoefficients
        DCCoefficients
        differentialDCCoefficients

        huffmanDCCodeLengths
        huffmanDCSymbolValues
        huffmanACCodeLengths
        huffmanACSymbolValues

        encodedDCCellArray
        encodedACCellArray

        deQuantisedCoefficients
        inverseTransformedData
        inverseTransformedAndShiftedData
        reconstructCoefficients

        reconstruction
        output
    end

    methods
        function obj = encoder(source, varargin)
            % Construct object setting defaults
            obj.setParameterDefaultValues;
            % Can set parameters on encoder
            if ~isempty(varargin)
                obj.setCodingParameters(varargin{:});
            end
            if exist('source','var')
                obj.readInput(source);
            end
        end

        %function set.input(obj, data)
        function readInput(obj, data)
            if exist('data', 'var') && ~isempty(data)
                %if source is a string read file, if its a matrix is image, if struct is struct image
                if isa(data, 'char')
                    obj.input = struct('fileName', data);
                    obj.imageMatrix = rgb2ycbcr(imread(data));
                    obj.imageStruct = struct('y', obj.imageMatrix(:,:,1),'cb', obj.imageMatrix(:,:,2),'cr', obj.imageMatrix(:,:,3), 'mode', '4:4:4');
                elseif isa(data, 'struct')
                    obj.input = data;
                    obj.imageMatrix = Subsampling.subsampledToYCbCrImage(data);
                    obj.imageStruct = data;
                elseif isa(data, 'numeric')
                    obj.input = struct('matrix', data);
                    obj.imageMatrix = data;
                    obj.imageStruct = struct('y', obj.imageMatrix(:,:,1),'cb', obj.imageMatrix(:,:,2),'cr', obj.imageMatrix(:,:,3), 'mode', '4:4:4');
                else
                    throw(MException('JPEGEncoder:input', 'The input image data must be either a struct with y, cb and cr fields corresponding to the 3 channels, a string file name to read, or a ycbcr image matrix.'));
                end
            end
        end

        function setParameterDefaultValues(obj)
            obj.setCodingParameters('quality', 60, 'subsampling', '4:2:0', ...
                'DoEntropyCoding', true, 'DoBitStream', true, 'DoCustomHuffmanTables', false, 'DoReconstruction', false, 'DoRunLengthCoding', true, 'DoReordering', true, 'DoDCDifferentials', true, ...
                'Verbose', false, 'BuiltIns', false);
        end

        function setCodingParameters(obj, varargin)
            for k=1:2:size(varargin,2)
                switch lower(varargin{k})
                    case 'quality'
                        if isa(varargin{k+1}, 'numeric')
                            obj.qualityFactor = varargin{k+1};
                        else
                            throw(MException('JPEGEncoder:setCodingParameters', 'The quality factor should be a numeric value.'));
                        end
                    case 'subsampling'
                        if isa(varargin{k+1}, 'char')
                            obj.chromaSamplingMode = varargin{k+1};
                        else
                            throw(MException('JPEGEncoder:setCodingParameters', 'The chroma sampling mode should be a string value. To see supported modes run ''Subsampling.supportedModes''.'));
                        end
                    case 'dostagesafterquantisation'
                        c = varargin{k+1};
                        obj.isEnabledStage.reOrderingCoefficients = c;
                        obj.isEnabledStage.runLengthCoding = c;
                        obj.isEnabledStage.differentialDC = c;
                        obj.isEnabledStage.entropyCoding = c;
                        obj.isEnabledStage.createBitStream = c;
                    case 'dorunlengthcoding'
                        obj.isEnabledStage.runLengthCoding = varargin{k+1};
                    case 'doreordering'
                        obj.isEnabledStage.reOrderingCoefficients = varargin{k+1};
                    case 'dodcdifferentials'
                        obj.isEnabledStage.differentialDC = varargin{k+1};
                    case 'docustomhuffmantables'
                        obj.isEnabledStage.customHuffmanTables = varargin{k+1};
                    case 'doentropycoding'
                        obj.isEnabledStage.entropyCoding = varargin{k+1};
                    case 'dobitstream'
                        obj.isEnabledStage.createBitStream = varargin{k+1};
                    case 'doreconstruction'
                        obj.doReconstruction = varargin{k+1};
                    case 'verbose'
                        obj.verbose = varargin{k+1};
                    case 'builtins'
                        obj.useBuiltInMethods = varargin{k+1};
                    case 'coefficientmap'
                        obj.basisCoefficientMap = varargin{k+1};
                end
            end

            % ************************************************************
            % TODO throw exception on invalid combos
        end

        function reset(obj)
            % Reset everything thus clearing up memory as well
            % Use introspection to get all properties on class and reset
            % them
            metaClassObject = metaclass(obj);
            for i=1:length(metaClassObject.Properties)
                obj.(metaClassObject.Properties{i}.Name) = [];
            end

            obj.setParameterDefaultValues;
        end

        function success = encodeToFile(obj, fileName, varargin)
            % ------------------------------------------
            % Encode Baseline DCT JPEG and write to file
            % ------------------------------------------
            % Refs:
            %
            % Parameters:
            %
            % Returns:
            %
            data = obj.encode(varargin{:});
            if isempty(data)
                disp('Encoding failed, or entropy coding was disabled on parameter list.');
                success = false;
            elseif islogical(data)
                success = Utilities.writeBinaryFileFromArray(fileName, Utilities.logicalArrayToUnsignedNumericArray(data));
            else
                success = Utilities.writeBinaryFileFromArray(fileName, data);
            end
        end

        function stream = encode(obj, varargin)
            % ------------------------
            % Encode Baseline DCT JPEG
            % ------------------------
            %
            % This function implements the main entropy point into the
            % actual coding process. It either uses the already set coding
            % parameters or parses them off the variable length parameter
            % list. Note that if entropy decoding is disabled the output of
            % the function will be an empty array and any prior state of
            % the entropy coding process will be cleared.
            %
            % Refs:
            % Baseline process: CCITT Rec. T.81 (1992 E) p.87
            %
            % Parameters:
            %
            % Returns:
            %   stream: (doEntropyCoding == true) : a logical array of bits
            %               representing the final coded file.
            %           (doEntropyCoding == false) : an empty array

            obj.setCodingParameters(varargin{:});

            if obj.isEnabledStage.entropyCoding; isCoding = 'on'; else isCoding = 'off'; end
            if obj.doReconstruction; isRec = 'on'; else isRec = 'off'; end
            if obj.verbose; disp(['Start encoding: (entropy coding: ' isCoding ', reconstruction: ' isRec ') -- Quality Factor: ' num2str(obj.qualityFactor) ', chroma sampling mode: ' obj.chromaSamplingMode]); end

            % If subsampling is necessary make sure it has been performed
            if isa(obj.imageStruct, 'struct')
                % For each colour channel
                if ~isfield(obj.imageStruct, 'y')
                    throw(MException('JPEGEncoder:encode', 'No ''y'' channel was found on the source image.'));
                end
                if ~isfield(obj.imageStruct, 'cb')
                    throw(MException('JPEGEncoder:encode', 'No ''cb'' channel was found on the source image.'));
                end
                if ~isfield(obj.imageStruct, 'cr')
                    throw(MException('JPEGEncoder:encode', 'No ''cr'' channel was found on the source image.'));
                end

                if isfield(obj.imageStruct, 'mode')
                    if strcmp(obj.imageStruct.mode, obj.chromaSamplingMode)
                        % already ok
                    else
                        % convert
                        obj.imageStruct = Subsampling.ycbcrImageToSubsampled(Subsampling.subsampledToYCbCrImage(obj.imageStruct), 'Mode', obj.chromaSamplingMode );
                    end
                else
                    % struct but no mode
                    throw(MException('JPEGEncoder:encode', 'No ''mode'' was found on the source image.'));
                end
            else
                % no struct so create from matrix
                obj.imageStruct = Subsampling.ycbcrImageToSubsampled( obj.imageMatrix, 'Mode', obj.chromaSamplingMode );
            end

            obj.luminanceScaledQuantisationTable = TransformCoding.qualityFactorToQuantisationTable(TransformCoding.luminanceQuantisationTable, obj.qualityFactor);
            obj.chromaScaledQuantisationTable = TransformCoding.qualityFactorToQuantisationTable(TransformCoding.chromaQuantisationTable, obj.qualityFactor);

            obj.transformAndEntropyCode();

            if obj.isEnabledStage.createBitStream
                % Create the output bitstream
                stream = obj.createBitStream();
            else
                stream = [];
            end
        end
    end

    methods (Access='protected')

        function transformAndEntropyCode(obj)
            if obj.useBuiltInMethods
                methods = struct('DCT', @dct2, 'IDCT', @idct2);
            else
                methods = struct('DCT', @ThirdParty.AMyronenko.mirt_dctn, 'IDCT', @ThirdParty.AMyronenko.mirt_idctn);
            end
            % Perform the data level shift. This is part of the JPEG
            % standard. It helps reduce the magnitude of the DC coefficient
            % so it is in the order of magnitude of the data type used for
            % the AC coefficient coding process (e.g. 8-bit values).
            % See the methods docs for more.
            obj.levelShiftInputImage();

            imageSize = size(obj.imageMatrix);

            % Perform the DCT. Here blkproc handles image extension for the
            % edge blocks smaller than 8x8.
            % TODO: Reference & description
            obj.coefficients = cellfun(@(channel)(...
                                    blkproc(channel, [8 8], methods.DCT)...
                                ), obj.imageStruct.levelShiftedChannel, 'UniformOutput', false);

            % Perform quantisation on each channel's coefficients.
            % Luminance and chroma have different quantisation tables.
            if imageSize(3) > 1
                qTables = {obj.luminanceScaledQuantisationTable obj.chromaScaledQuantisationTable obj.chromaScaledQuantisationTable};
            else
                qTables = {obj.luminanceScaledQuantisationTable};
            end
            obj.quantisedCoefficients = cellfun(@(channel, table)(...
                                            blkproc(channel, [8 8], @(block)TransformCoding.quantisationWithTable(block, table)) ...
                                        ), obj.coefficients, qTables, 'UniformOutput', false);

            if ~isempty(obj.basisCoefficientMap)
                obj.quantisedCoefficients = cellfun(@(channel)(...
                                            blkproc(channel, [8 8], @(block)(double(obj.basisCoefficientMap).*block)) ...
                                        ), obj.quantisedCoefficients, 'UniformOutput', false);
            end

            % Do Zigzag reordering of coefficients. This process collects
            % the highest energy coefficients of the DCT into the start of
            % the array of coefficients
            if obj.isEnabledStage.reOrderingCoefficients
                obj.orderedCoefficients = cellfun(@(coeffs)(...
                                    blkproc(coeffs, [8 8], @TransformCoding.coefficientOrdering)...
                                ), obj.quantisedCoefficients, 'UniformOutput', false);
            end

            % Zeros-run-length code the coefficients. This is efficient
            % after zigzag ordering as many zeros will have been created in
            % the low energy coefficients which are now together towards
            % the end of the ordered coefficient array.
            % blkproc can only return numeric array data of equal size for
            % each block. Hence zerosRunLengthCoding returns the zeroLength
            % and values in a concatenated 126 values array, with -1s
            % padding the unused values (lengths:values)
            if obj.isEnabledStage.runLengthCoding
                obj.zerosRunLengthCodedOrderedACCoefficients = cellfun(@(coeffs)(...
                                    TransformCoding.zerosRunLengthCoding(coeffs)...
                                ), obj.orderedCoefficients, 'UniformOutput', false);
            end

            % Get a list of DC coefficient for each channel
            if obj.isEnabledStage.differentialDC
                obj.DCCoefficients = cellfun(@(coeffs)(...
                                    coeffs(:, 1:64:end)...
                                ), obj.orderedCoefficients, 'UniformOutput', false);
                % Differentially code the DC value
                obj.differentialDCCoefficients = cellfun(@(coeffs)(...
                                    TransformCoding.differentiallyCodeDC(coeffs)...
                                ), obj.DCCoefficients, 'UniformOutput', false);
            end

            % If reconstruction is enabled the encoder will to the reverse
            % of the above process so that the final image can be viewed
            % without having to perform entropy coding and then decoding
            % the result
            if obj.doReconstruction

                obj.deQuantisedCoefficients = cellfun(@(channel, table)(...
                                            blkproc(channel, [8 8], @(block)TransformCoding.dequantisationWithTable(block, table)) ...
                                        ), obj.quantisedCoefficients, qTables, 'UniformOutput', false);

                obj.inverseTransformedData = cellfun(@(channel)(...
                                                blkproc(channel, [8 8], methods.IDCT)...
                                        ), obj.deQuantisedCoefficients, 'UniformOutput', false);

                obj.inverseTransformedAndShiftedData = cellfun(@(channel)(uint8(double(channel) + 128)), obj.inverseTransformedData, 'UniformOutput', false);

                structImage = cell2struct(obj.inverseTransformedAndShiftedData, {'y', 'cb', 'cr'}, 2);
                structImage.mode = obj.chromaSamplingMode;
                obj.reconstruction = structImage;
            end

            % Perform entropy coding
            if obj.isEnabledStage.entropyCoding

                % Huffman Code DC Values
                if obj.isEnabledStage.customHuffmanTables
                    % Custom tables from data statistics
                    %
                    % If enabled create custom huffman tables
                    % The symbols for DC are actually the length in bits of
                    % the data value
                    % For luminance channel
                    data = ceil( log2(abs(obj.differentialDCCoefficients{1}) + 1) );
                    [obj.huffmanDCSymbolValues.luminance, obj.huffmanDCCodeLengths.luminance] = EntropyCoding.generateHuffmanCodeLengthAndSymbolTablesFromData( data );
                    % For the chroma channels
                    data = ceil( log2(abs([obj.differentialDCCoefficients{2} obj.differentialDCCoefficients{3}]) + 1) );
                    [obj.huffmanDCSymbolValues.chroma, obj.huffmanDCCodeLengths.chroma] = EntropyCoding.generateHuffmanCodeLengthAndSymbolTablesFromData( data );
                    clear data
                else
                    % Ref: CCITT Rec. T.81 (1992 E) p.88
                    %
                    % The following generates the table of Huffman codes which
                    % represent the 12 luminance DC difference categories (or
                    % ranges). The codes are generated so that there is no chance
                    % of a code consisting only of 1s.
                    obj.huffmanDCCodeLengths.luminance     = EntropyCoding.LuminanceDCHuffmanCodeCountPerCodeLength;
                    obj.huffmanDCSymbolValues.luminance    = EntropyCoding.LuminanceDCHuffmanSymbolValuesPerCode;
                    % The Chroma DC Huffman code table for the 12 categories
                    obj.huffmanDCCodeLengths.chroma     = EntropyCoding.ChromaDCHuffmanCodeCountPerCodeLength;
                    obj.huffmanDCSymbolValues.chroma    = EntropyCoding.ChromaDCHuffmanSymbolValuesPerCode;
                end
                huffmanCodesForDC{1} = obj.createHuffmanCodes(obj.huffmanDCCodeLengths.luminance, obj.huffmanDCSymbolValues.luminance);
                huffmanCodesForDC{2} = obj.createHuffmanCodes(obj.huffmanDCCodeLengths.chroma, obj.huffmanDCSymbolValues.chroma);

                % The DC value for each block in raster order
                obj.encodedDCCellArray = arrayfun(@(channelID)( ...
                                    EntropyCoding.encodeDCValues(obj.differentialDCCoefficients{channelID}, huffmanCodesForDC{floor(channelID/2)+1}) ...
                                ), 1:imageSize(3), 'UniformOutput', false);

                % Huffman Code AC Values
                if obj.isEnabledStage.customHuffmanTables
                    % If enabled create custom huffman tables
                    % The data huffman coded by the table is the RS values.
                    blocks = reshape(obj.zerosRunLengthCodedOrderedACCoefficients{1}.', 126, []).';
                    rsValues = blocks(:,1:63); % take only RS values
                    rsValues(rsValues < 0) = []; % remove any unset values
                    [obj.huffmanACSymbolValues.luminance, obj.huffmanACCodeLengths.luminance] = EntropyCoding.generateHuffmanCodeLengthAndSymbolTablesFromData( rsValues );
                    % For the chroma channels
                    blocks = reshape(obj.zerosRunLengthCodedOrderedACCoefficients{2}.', 126, []).';
                    rsValues = blocks(:,1:63);
                    rsValues(rsValues < 0) = [];
                    blocks = reshape(obj.zerosRunLengthCodedOrderedACCoefficients{3}.', 126, []).';
                    rsValues1 = blocks(:,1:63);
                    rsValues1(rsValues1 < 0) = [];
                    rsValues = [rsValues rsValues1];
                    [obj.huffmanACSymbolValues.chroma, obj.huffmanACCodeLengths.chroma] = EntropyCoding.generateHuffmanCodeLengthAndSymbolTablesFromData( rsValues );
                    clear blocks rsValues rsValues1
                else
                    % Ref: CCITT Rec. T.81 (1992 E) p.89
                    % Using the stardard Huffman code tables

                    %   Luminance
                    obj.huffmanACCodeLengths.luminance  = EntropyCoding.LuminanceACHuffmanCodeCountPerCodeLength;
                    obj.huffmanACSymbolValues.luminance = EntropyCoding.LuminanceACHuffmanSymbolValuesPerCode;
                    %   Chroma
                    obj.huffmanACCodeLengths.chroma     = EntropyCoding.ChromaACHuffmanCodeCountPerCodeLength;
                    obj.huffmanACSymbolValues.chroma    = EntropyCoding.ChromaACHuffmanSymbolValuesPerCode;
                end
                huffmanCodesForAC{1} = obj.createHuffmanCodes(obj.huffmanACCodeLengths.luminance, obj.huffmanACSymbolValues.luminance);
                huffmanCodesForAC{2} = obj.createHuffmanCodes(obj.huffmanACCodeLengths.chroma, obj.huffmanACSymbolValues.chroma);

                % Note, at this point the zerosRunLengthCoding has already
                % handled the special RS value cases, so the entries need
                % simply encoding (-1 values are to be ignored)
                obj.encodedACCellArray = arrayfun(@(channelID)( ...
                                                    obj.encodeACCoefficientsOfChannel(channelID, huffmanCodesForAC{floor(channelID/2)+1}) ...
                                                ), 1:imageSize(3), 'UniformOutput', false);
            else
                obj.encodedDCCellArray = [];
                obj.encodedACCellArray = [];
            end
        end

        % Helper Methods
        % TODO : make this a package function
        function levelShiftInputImage(obj)
            % -----------
            % Level Shift
            % -----------
            % By adjusting the range of the input data from 0-255 to
            % -128-127 the DCT DC value range is changed to be in a similar
            % integer range to that of the AC values making implementations
            % simpler on particular integer types. The AC values should be
            % level shift independant
            % Ref:
            %   CCITT Rec. T.81 (1992 E) p.26
            %   http://compgroups.net/comp.compression/Level-Shift-in-JPEG-optional-or-mandatory

            %%%%% After a non-differential frame decoding process computes
            %%%%% the IDCT and produces a block of reconstructed image samples, an inverse level shift shall restore the samples to the unsigned representation by adding 2P ? 1 and clamping the results to the range 0 to 2P ? 1.
            if isfield(obj.imageStruct, {'y', 'cb', 'cr'})
                channels = {'y', 'cb', 'cr'};
            elseif isfield(obj.imageStruct, {'r', 'g', 'b'})
                channels = {'r', 'g', 'b'};
            else
                throw(MException('JPEGEncoder:levelShiftInputImage', 'For now only y,cb,cr or r,g,b images are supported'));
            end
            obj.imageStruct.levelShiftedChannel = cellfun(@(channel)(int8(double(obj.imageStruct.(channel)) - 128)), channels, 'UniformOutput', false);
        end

        function encodedArray = encodeACCoefficientsOfChannel(obj, channelID, huffmanCodes)
            % first find -1s
            flatCoeffs = reshape(obj.zerosRunLengthCodedOrderedACCoefficients{channelID}.', [1 numel(obj.zerosRunLengthCodedOrderedACCoefficients{channelID})]);
            blockStartIndexes = 1:126:length(flatCoeffs);
            encodedArray = cell(1, length(blockStartIndexes));
            % TODO: turn into private method and arrayfun
            for i = 1:length(blockStartIndexes)
                % For each block (raster order)
                idx = blockStartIndexes(i);
                lengths = flatCoeffs(idx:idx+62);
                values = flatCoeffs(idx+63:idx+125);
                lastIndex = find( lengths < 0, 1);
                lengths = lengths(1:lastIndex - 1);
                values = values(1:lastIndex - 1);
                encodedArray{i} = arrayfun(@(runLength, value)(EntropyCoding.encodeACZerosRunLengthValue(runLength, value, huffmanCodes)), ...
                                                lengths, ... % lengths
                                                values, ... % values
                                                'UniformOutput', false);
            end
        end

        function huffmanCodesCellArray = createHuffmanCodes(obj, bits, huffvals)
            [huffsize, lastk] = EntropyCoding.generateTableOfHuffmanCodeSizes(bits);
            huffcode = EntropyCoding.generateTableOfHuffmanCodes(huffsize);
            [ehufco, ehufsi] = EntropyCoding.generateEncodingProcedureCodeTables( huffvals, huffcode, huffsize, lastk );
            huffmanCodesCellArray = arrayfun(@Utilities.decimalToLogical, ehufco, ehufsi, 'UniformOutput', false);
        end

        function stream = createBitStream(obj)
            % ----------------
            % Create bitstream
            % ----------------
            % Ref: CCITT Rec. T.81 (1992 E)
            %
            % Note Baseline DCT mode JPEG (SOF0) is the only supported mode
            % in this application.
            %
            % The following describes the hierarchy of the JPEG bitstream
            % created here. This is essentially the minimum requirements.
            %
            % A JPEG bitstream is as follows:
            % 1) Start of image marker (SOI)
            % 2) [FRAME]
            % 3) End of image marker (EOI)
            %
            % A [FRAME] is as follows:
            % 1) [TABLES]
            % 2) [FRAMEHEADER]
            % 3) [SCAN]
            % 4) <[SCAN>] <- optionally more scans containing channels
            % 5) ...
            %
            % Note: all channels can be interleaved into 1 SCAN or they can
            % be kept non-interleaved with 1 SCAN segment per channel.
            %
            % A [FRAMEHEADER] is composed of:
            % 1) A Start of Frame Marker defining the mode (SOFx)
            % 2) 8 bytes of frame info, layed out as: Header length (Lf, 2
            % bytes), data precision (P, 1 bytes), frame height (Y, 2
            % bytes), frame width (X, 2 bytes), number of channels in image
            % (Nf, 1 byte) and then for each channel 3 bytes, the first an
            % ID for the channel (Cx, 1 byte), the second the sampling
            % factors for the channel in both the horizontal and vertical
            % directions (Hx:Vx both 4 bits packed into 1 byte) and an ID
            % of the Quantisation table to use for the channel (Tqx, 1
            % byte).
            %
            % A [SCAN] is composed of:
            % 1) <[TABLES]> optional
            % 2) [SCANHEADER]
            % 3) [Entropy coded segment ECS]
            %
            % A [SCANHEADER] is composed of:
            % 1) A Start of Scan marker (SOS)
            % 2) 6 + (2*3) bytes (for 3 channels) comprising of: Header length
            % (Ls, 2 bytes), number of channels in scan (Ns, 1 byte), a 2
            % byte sequence for each colour channel: the ID (Csi 1 byte),
            % then 2 packed nibbles of the DC entropy coding table ID & the
            % AC entropy coding table ID (Tdi:Tai, 1 byte). These are
            % followed by the Start of predictor ID (Ss, 1 byte), the End
            % of predictor ID (Se, 1 byte) and then 1 packed byte
            % comprising of Successive approximation bit position high and
            % the Successive approximation bit position low (Ah:Al, 1
            % byte). Note for Sequential Baseline DCT JPEG, Ss = 0, Se =
            % 63, Ah = 0 and Al = 0
            %
            % An [ECS] (entropy coded segment) is as follows:
            % 1)
            %
            % The [TABLES] for quantisation and Huffman coding are as
            % follows:
            % * Quantisation Tables:
            %   1) Define Quantisation Table marker (DQT)
            %   2) Segment length (Lq, 2 bytes) followed, for each table to
            %      be specified, by: 1 packed byte where the high four bits
            %      are the Precision of entries, (0 for 8 bit, 1 for
            %      16bit) and the low 4 bits are the ID of the table
            %      (Pq:Tq, 1 byte), followed by the 64 quantisation table
            %      entries in zig-zag order (64 bytes (or 128 if 16bit Pq))
            %
            % * Huffman Tables:
            %   1) Define Huffman Table marker (DHT)
            %   2) Segment length (Lh, 2 bytes) followed, for each table to
            %      be specified: 1 packed byte with top 4 bits specifying
            %      the type of table (0 for DC, 1 for AC) and lower 4 bits
            %      are the table ID (Tc:Th, 1 bytes), 16 bytes specifying
            %      the number of Huffman codes per code length Li (Li, i =
            %      1:16, 16 bytes), then come the values associated with
            %      each Huffman code. The V{i,j} value is the value for the
            %      j'th code of length i. The values are grouped in length
            %      order.
            %
            % Since a number of segments are not used in the implementation
            % they are not discussed further. Please refer to the standards
            % documentation for more. Markers: DNL, DRI, RST, COM, APP ETC

            % Ref: CCITT Rec. T.81 (1992 E)	p. 32
            % SOI : Marks start of a JPEG image
            markerStartOfImage          = Utilities.hexToShort('FFD8');
            % EOI : Marks the end of the JPEG file
            markerEndOfImage            = Utilities.hexToShort('FFD9');

            frameHeader = obj.createBitStreamForFrameHeader();
            quantisationTables = obj.createBitStreamForQuantisationTables();
            huffmanTables = obj.createBitStreamForHuffmanTables();

            pixelBits = obj.createBitStreamForPixelData();

            stream = cat(2, markerStartOfImage, ... % SOI
                quantisationTables, ... % Tables for this image
                huffmanTables, ...
                frameHeader, ...
                pixelBits, ...
                markerEndOfImage);  % EOI

            obj.output = stream;
        end

        function bits = createBitStreamForPixelData(obj)
            % TODO: this needs to be modified to support single channel
            % images

            scanHeaderY = obj.createBitStreamForScanHeaderForSingleChannel(1);
            entropyCodedSegmentY = obj.createBitStreamForEntropyCodedDataForSingleChannel(1);

            scanHeaderCb = obj.createBitStreamForScanHeaderForSingleChannel(2);
            entropyCodedSegmentCb = obj.createBitStreamForEntropyCodedDataForSingleChannel(2);

            scanHeaderCr = obj.createBitStreamForScanHeaderForSingleChannel(3);
            entropyCodedSegmentCr = obj.createBitStreamForEntropyCodedDataForSingleChannel(3);
            bits = cat(2, ...
                scanHeaderY,...
                entropyCodedSegmentY, ...
                scanHeaderCb,...
                entropyCodedSegmentCb, ...
                scanHeaderCr,...
                entropyCodedSegmentCr);
        end

        function bits = createBitStreamForEntropyCodedDataForSingleChannel(obj, channelID)
            % -----------
            % Entropy Coded Segment
            % -----------

            bits = logical([]);

            for i=1:length(obj.encodedDCCellArray{channelID})
                bits = cat(2, bits, obj.encodedDCCellArray{channelID}{i}, cell2mat(obj.encodedACCellArray{channelID}{i}));
            end

            bits = Utilities.padLogicalArray(bits, 8, 1);
            bits = Utilities.byteStuffing(bits, 8);

        end

        function bits = createBitStreamForScanHeaderForSingleChannel(obj, channelID)
            % -----------
            % Scan Header
            % -----------
            % Ref: CCITT Rec. T.81 (1992 E)	p.37

            % From real JPEG image using 4:2:0
            % FF DA 00 0C 03 01 00 02 11 03 11 00 3F 00
            % SOS, Ls(12), Ns(3), Cs1(1=Y), Td1(0):Ta1(0), Cs2(2=Cb), Td2(1):Ta2(1), Cs3(3=Cr), Td3(1):Ta3(1), Ss(0), Se(3F), Ah(0):Al(0)

            % SOS marker
            markerStartOfScan   = Utilities.hexToShort('FFDA');

            % Ls    (2 bytes)
            segmentLength       = Utilities.decimalToShort(6 + (2*1));
            % Ns    (1 byte)
            componentCount      = Utilities.decimalToByte(1);

            % CsX   (1 byte)
            channelIDByte       = Utilities.decimalToByte(channelID);
            % TdX:TaX (1 byte)
            channelTableIDs     = Utilities.decimalNibblesToByte(floor(channelID/2), floor(channelID/2));

            % Ss    (1 byte)
            startPredictorID    = Utilities.decimalToByte(0);
            % Se    (1 byte)
            endPredictorID      = Utilities.decimalToByte(63);
            % Ah:Al (1 byte)
            successiveApproximationBitPosition = Utilities.decimalNibblesToByte(0, 0);

            bits = cat(2, ...
                markerStartOfScan, ...
                segmentLength, ...
                componentCount, ...
                channelIDByte, ...
                channelTableIDs, ...
                startPredictorID, ...
                endPredictorID, ...
                successiveApproximationBitPosition ...
                );
        end

        function bits = createBitStreamForFrameHeader(obj)
            % -------------------
            % Frame Header Format
            % -------------------
            % Ref: CCITT Rec. T.81 (1992 E)	p. 35
            % and
            % http://en.wikibooks.org/wiki/JPEG_-_Idea_and_Practice/The_header_part

            % SOF0 : Marks that this is a Baseline DCT mode JPEG
            markerStartOfFrame_Mode0    = Utilities.hexToShort('FFC0');

            % Here is a header from a real JPEG using 4:2:2
            % FF C0, 00 11, 08, 01 90, 02 80, 03, 01, 21, 00, 02, 11, 01, 03, 11, 01
            % Using the notation of the T.81:
            % SOF0, Lf(17), P(8), Y(400), X(640), Nf(3), Ci(1=Y), Hi(2):Vi(1), Tqi(0), Ci(2=Cb), Hi(1):Vi(1), Tqi(1), Ci(3=Cr), Hi(1):Vi(1), Tqi(1)
            % followed by the huffman tables

            % From a real JPEG using 4:4:4 then Hi = 1 Vi = 1 for all
            % From a real JPEG using 4:2:0 then Hi = 2 Vi = 2 for Y and 1,1
            % for chroma. For a more detailed explaination see the comments
            % in the following method:
            [yHi yVi cbHi cbVi crHi crVi] = Subsampling.modeToHorizontalAndVerticalSamplingFactors(obj.imageStruct.mode);

            % Lf    (2 bytes)
            segmentSOFLength            = Utilities.decimalToShort(8 + 3 * (3));%dec2bin(8 + 3 * (3), 16); % includes the 2 bytes needed for the length itself
            % P     (1 byte)
            dataByteSize                = Utilities.decimalToByte(8);%dec2bin(8,8); % 8 bit bytes , would be 12 in extended mode but im not supporting it
            % Y     (2 byte)
            imageHeight                 = Utilities.decimalToShort(size(obj.imageStruct.y,1));%dec2bin(size(obj.imageStruct.y,1),16);
            % X     (2 byte)
            imageWidth                  = Utilities.decimalToShort(size(obj.imageStruct.y,2));%dec2bin(size(obj.imageStruct.y,2),16);
            % Nf    (1 byte)
            numberOfChannels            = Utilities.decimalToByte(3);%dec2bin(3, 8);

            % Ci1   (1 byte)
            yComponentIdentifier        = Utilities.decimalToByte(1);%dec2bin(1,8);
            % Hi1   (1 nibble)
            % Vi1   (1 nibble)
            yHorizontalVerticalSamplingFactor       = Utilities.decimalNibblesToByte(yHi, yVi);
            % Tqi1  (1 byte)
            yQuantisationTableDestinationSelector   = Utilities.decimalToByte(0);%dec2bin(0,8); %Table0 for Y

            % Ci2   (1 byte)
            cbComponentIdentifier       = Utilities.decimalToByte(2);%dec2bin(2,8);
            % Hi2   (1 nibble)
            % Vi2   (1 nibble)
            cbHorizontalVerticalSamplingFactor      = Utilities.decimalNibblesToByte(cbHi, cbVi);
            % Tqi2  (1 byte)
            cbQuantisationTableDestinationSelector  = Utilities.decimalToByte(1);%dec2bin(1,8); %Table1 for chroma

            % Ci3   (1 byte)
            crComponentIdentifier       = Utilities.decimalToByte(3);%dec2bin(3,8);
            % Hi3   (1 nibble)
            % Vi3   (1 nibble)
            crHorizontalVerticalSamplingFactor      = Utilities.decimalNibblesToByte(crHi, crVi);
            % Tqi3  (1 byte)
            crQuantisationTableDestinationSelector  = Utilities.decimalToByte(1);%dec2bin(1,8);

            bits = cat(2,markerStartOfFrame_Mode0, ...% SOF: start frame header
                segmentSOFLength, ...
                dataByteSize, ...
                imageHeight, ...
                imageWidth, ...
                numberOfChannels, ...
                yComponentIdentifier, ... %yHorizontalSamplingFactor, yVerticalSamplingFactor, ...
                yHorizontalVerticalSamplingFactor, ...
                yQuantisationTableDestinationSelector, ...
                cbComponentIdentifier, ... %cbHorizontalSamplingFactor, cbVerticalSamplingFactor, ...
                cbHorizontalVerticalSamplingFactor, ...
                cbQuantisationTableDestinationSelector, ...
                crComponentIdentifier, ... %crHorizontalSamplingFactor, crVerticalSamplingFactor, ...
                crHorizontalVerticalSamplingFactor, ...
                crQuantisationTableDestinationSelector);
        end

        function bits = createBitStreamForQuantisationTables(obj)
            % --------------------------
            % Quantisation Table entries
            % --------------------------
            % Ref: CCITT Rec. T.81 (1992 E)	p.39
            %
            % TODO MOVE DOCS HERE FROM THE createBitStream method!
            %
            % Note: This method encodes 2 quantisation tables, one for
            % luminance channels and one for chroma.

            % DQT
            markerDefineQuantisationTable   = Utilities.hexToShort('FFDB');

            % Lq
            segmentLength                   = Utilities.decimalToShort(2 + (2*65)); % 2 tables of 65 bytes each

            % Y Table
            % Pq:Tq
            luminanceTablePrecisionAndID    = Utilities.decimalNibblesToByte(0, 0); % 8 bit, table 0
            % Entries - arrayfun expects a scalar return so instead set
            % UniformOutput = false and then use cell2mat on the resulting
            % cell array to flatten it
            luminanceTableEntries           = cell2mat( arrayfun(@Utilities.decimalToByte, ...
                                                TransformCoding.coefficientOrdering( ...
                                                    obj.luminanceScaledQuantisationTable), 'UniformOutput', false));

            % Chroma Table
            % Pq:Tq
            chromaTablePrecisionAndID       = Utilities.decimalNibblesToByte(0, 1); % 8 bit, table 1
            % Entries
            chromaTableEntries              = cell2mat( arrayfun(@Utilities.decimalToByte, ...
                                                TransformCoding.coefficientOrdering( ...
                                                    obj.chromaScaledQuantisationTable), 'UniformOutput', false));

            bits = cat(2, ...
                markerDefineQuantisationTable, ...
                segmentLength, ...
                luminanceTablePrecisionAndID, ...
                luminanceTableEntries, ...
                chromaTablePrecisionAndID, ...
                chromaTableEntries ...
                );
        end

        function bits = createBitStreamForHuffmanTables(obj)
            % --------------------------
            % Huffman Table entries
            % --------------------------
            % Ref: CCITT Rec. T.81 (1992 E)	p.40

            % 4 TABLES

            % Define Huffman Table (DHT)
            markerDefineHuffmanTable    = Utilities.hexToShort('FFC4');

            % Lh - 4 tables * (17 bytes + numberOfValuesPerTable)
            segmentLength               = Utilities.decimalToShort(2 + ...
                                            (17 + length(obj.huffmanDCSymbolValues.luminance)) + ...
                                            (17 + length(obj.huffmanACSymbolValues.luminance)) + ...
                                            (17 + length(obj.huffmanDCSymbolValues.chroma)) + ...
                                            (17 + length(obj.huffmanACSymbolValues.chroma)));

            % Per table:
            % Luminance (ID 0) DC
            % Tc:Th
            luminanceTableDCTypeAndID    = Utilities.decimalNibblesToByte(0, 0);

            % Li
            luminanceTableDCLengthCounts = cell2mat( arrayfun(@Utilities.decimalToByte,...
                                                    obj.huffmanDCCodeLengths.luminance, 'UniformOutput', false));
            % Vi,j
            luminanceTableDCValues      = cell2mat( arrayfun(@Utilities.decimalToByte, ...
                                                    obj.huffmanDCSymbolValues.luminance, 'UniformOutput', false));

            % AC
            % Tc:Th
            luminanceTableACTypeAndID    = Utilities.decimalNibblesToByte(1, 0);

            % Li
            luminanceTableACLengthCounts = cell2mat( arrayfun(@Utilities.decimalToByte, ...
                                                    obj.huffmanACCodeLengths.luminance, 'UniformOutput', false));
            % Vi,j
            luminanceTableACValues      = cell2mat( arrayfun(@Utilities.decimalToByte, ...
                                                    obj.huffmanACSymbolValues.luminance, 'UniformOutput', false));

            % Chroma (ID 1) DC
            % Tc:Th
            chromaTableDCTypeAndID      = Utilities.decimalNibblesToByte(0, 1);

            % Li
            chromaTableDCLengthCounts   = cell2mat( arrayfun(@Utilities.decimalToByte, ...
                                                    obj.huffmanDCCodeLengths.chroma, 'UniformOutput', false));
            % Vi,j
            chromaTableDCValues         = cell2mat( arrayfun(@Utilities.decimalToByte, ...
                                                    obj.huffmanDCSymbolValues.chroma, 'UniformOutput', false));

            % AC
            % Tc:Th
            chromaTableACTypeAndID      = Utilities.decimalNibblesToByte(1, 1);

            % Li
            chromaTableACLengthCounts   = cell2mat( arrayfun(@Utilities.decimalToByte, ...
                                                    obj.huffmanACCodeLengths.chroma, 'UniformOutput', false));
            % Vi,j
            chromaTableACValues         = cell2mat( arrayfun(@Utilities.decimalToByte, ...
                                                    obj.huffmanACSymbolValues.chroma, 'UniformOutput', false));

            bits = cat(2, ...
                markerDefineHuffmanTable, ...
                segmentLength, ...
                luminanceTableDCTypeAndID, ...
                luminanceTableDCLengthCounts, ...
                luminanceTableDCValues, ...
                luminanceTableACTypeAndID, ...
                luminanceTableACLengthCounts, ...
                luminanceTableACValues, ...
                chromaTableDCTypeAndID, ...
                chromaTableDCLengthCounts, ...
                chromaTableDCValues, ...
                chromaTableACTypeAndID, ...
                chromaTableACLengthCounts, ...
                chromaTableACValues ...
                );
        end
    end
end
