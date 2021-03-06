function[est_doa_vec,counts,az_grid,inc_grid,smoothed_hist] = est_doas_sspiv(z,fs,mic,in_params)
% estimates the directions of arrival of up to nSrcMax sources using
% pseudointensity vector (PIV) method
% the histogrma grid is equally spaced (with possibly different resolutions) in 
% azimuth and inclination


%% parameters
% define defaults
params.c = soundspeed;              % speed of sound (m/s)
params.nSrcMax = 10;                % cant imagine trying to find more than that!
params.frame_duration = 0.008;      % stft frame in seconds
params.frame_overlap_frac = 0.75;   % stft frame overlap as fraction
params.az_space_deg = 2;            % angular resolution in azimuth (degrees)
params.inc_space_deg = 2;           % angular resolution in inclination (degrees)
params.sph_harmonic_order_max = 1;  % the maximum order of SH to compute in the spherical fourier transform
params.freq_min = 500;
params.freq_max = 4000;
params.smooth_sigma = 4;            % smoothing factor for histogram
params.time_span = 0.032;           % time range over which to smooth covariance matrix (s)
params.freq_span = 250;             % frequency range over which to smooth covariance matrix (Hz)


% use in_params to override the defaults
if nargin > 3 && ~isempty(in_params)
    params = override_valid_fields(params,in_params);
end

% deal with parameters whose defaults depend on the required inputs
if isempty(params.sph_harmonic_order_max)
    % use some basic logic to infer the maximum order
    % (there are better ways!)
    nSensors = size(mic.sensor_angle,1);
    params.sph_harmonic_order_max = fix(sqrt(nSensors)-1) - 1;
    warning('sph_harmonic_order_max was not specified so guessing...')
    fprintf('Using sph_harmonic_order_max: %d\n',params.sph_harmonic_order_max);
end


%% stft
nwin = round(params.frame_duration * fs);
nfft = nwin;
ninc = round((1-params.frame_overlap_frac) * params.frame_duration * fs);
win = hamming(nwin,'periodic');
[Z,pm] = stft(z,win,ninc,nfft,fs);


%% spherical harmonic transform
% - only do transform for frequencies we want to use

% determine valid frequency range for analysis
% - copy required parameters into a new stucture to pass in
sub_params.c  = params.c;
sub_params.freq_min  = params.freq_min;
sub_params.freq_max  = params.freq_max;
[min_f_bin,max_f_bin] = sh_valid_frequency_bins(mic, pm,...
    params.sph_harmonic_order_max, sub_params);

% remove entries from list of frequencies
pm.f = pm.f(min_f_bin:max_f_bin);

% do the sht, again only using the desired frequencies
Praw = sht(Z(min_f_bin:max_f_bin,:,:),mic,params.sph_harmonic_order_max);


%% mode strength compensation
% - includes frequency depenendent part of beamforming
% - since frequency range of interest is restricted we do not do anything
%   special to control white noise gain

% get the mode strength for mic configuration at each frequency and SH
%   b: [nFreq,sph_trunc_order+1] - mode stregnth
% i_b: [1 nSH] - indices required to expand (replicate) entries in b to
%      match the number of spherical harmonics
[b,i_b] = modeStrength(mic.sphType,mic.a,mic.a,pm.f,...
    params.sph_harmonic_order_max, params.c);
if any(isnan(b(:)))
    error('Need to deal with NaNs in modeStrength')
end

% apply the compensation
%     Praw: [nFreq,nSH,nFrames]
% b(:,i_b): [nFreq,nSH,1]
%    Pcomp: [nFreq,nSH,nFrames]
Pcomp = bsxfun(@rdivide,Praw,b(:,i_b));


%% sspiv
% compute smoothed covariance matrix for each time-freqeuncy region
% - convert smoothing region to number of bins
nAvgFrames = timespan2frames(fs,nwin,ninc,params.time_span);
nAvgFreq = freqspan2bins(fs,nfft,params.freq_span);

% get covariance in each TF regiop
[R, R_extras] = tf_smoothed_covariance(Pcomp,pm,nAvgFrames,nAvgFreq);

% do singular value decomposition
[Ucell,Scell] = svd_for_cells(R);

% sspivs is piv of 1-dimensional signal subspace at each TF region
% svr_ratio is the singular value ratio which can be used for the
% direct-path dominance test (not done here)
[sspivs,svr_ratio] = sspiv1(Ucell,Scell);


%% histogram
% - turn SSPIV at each TF-region into single Mx3 matrix
% - form a histogram of the directions
% - smooth the histogram to get final 2D representation
stacked_sspivs = reshape(permute(sspivs,[1 3 2]),[],3);
[counts,az_grid,inc_grid] = piv_hist(stacked_sspivs,params.az_space_deg,params.inc_space_deg);
[smoothed_hist] = smooth_histogram_pd(counts,params.smooth_sigma,az_grid,inc_grid);


%% doa est
% nSrcMax given as input paramter, or default at top of script, determines
% the maximum number of peaks in the srp that should be returned
% peak_vals could be used to select which of the identified peaks should be
% retained/discarded
[est_doa_vec,~,peak_vals] = sph_local_peaks_to_doa_vecs_with_peak_vals(...
    smoothed_hist, az_grid, inc_grid, params.nSrcMax);

