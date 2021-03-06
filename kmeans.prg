'*************************************************************************************************************************************************
' MOTIVATION: execute k-means clustering on a cross section or time series collection of series

' ARGUMENTS:

' 1) Mandatory -
'	a. k = the # of clusters to be generated

' 2) Optional -
'	a. quiet = shut off log messages (log messages left on if not specified)
'	b. iters = the number of full solution iterations to run (defaults to 1)
'	c. series = a space delimited string of series included in analysis (defaults to all series)
'	d. smpl = the sample to execute the procedure over (defaults to the current sample)
'		NOTE: can pass in standalone "all" or "@all" to change sample to all
'	e. impute | interpolate = whether to linearly interpolate missing values (defaults to not linearly interpolating)
'		NOTE: will error if asked to impute on a cross section workfile
'*************************************************************************************************************************************************

' *****************************************************************************
' *** EXTRACT PASSED IN ARGUMENTS & KEY PARAMETERS ***
' *****************************************************************************

' 1) silence log messages if running in quiet mode
if @hasoption("quiet") then
	logmode -logmsg
endif
logmsg ------ Executing k-means clustering!
logmsg

' 2) page frequency of page add-in is called on
if @ispanel then 
	seterr "ERROR: cannot call k means add-in on a panel work structure"
endif
%FREQ = @pagefreq

' 3) name of the current page when add-in is called
%PAGE_CALLED = @pagename

' 4) determine the sample
%SMPL = @equaloption("smpl")
if @hasoption("all") or @hasoption("@all") or @lower(%SMPL) = "all" or @lower(%SMPL) = "@all" then
	%SMPL = "@all"
endif
if %SMPL = NA then
	%SMPL = @pagesmpl
endif

' 5) find out how many clusters are being generated
!K = @val(@equaloption("k"))
if !K = NA then
	seterr "ERROR: User has not inputted a numeric argument for k in call to k-means clustering utility"
endif

' 6) find out how many iterations of k-means are to be done
!ITERS = @val(@equaloption("iters"))
if !ITERS = NA then
	!ITERS = 1 	

	logmsg ----- Setting # of k-means full iteration solutions to default of 1
	logmsg
endif

' 7) find out the series that are to be included in the analysis
%SERIES = @equaloption("SERIES")
' if series argument was not passed in, set arg equal to all series (excluding residuals)
if %SERIES = "" then
	%SERIES = @wlookup("*", "series")
	
	logmsg ----- No series argument passed in, defaulting to include all series
	logmsg
endif

'8) find out whether interpolation/imputation will occur (only valid for time series)
!IMPUTE = 0
if @hasoption("impute") or @hasoption("interpolate") then
	!IMPUTE = 1
endif
if !IMPUTE and %FREQ = "u" then
	seterr "ERROR: cannot impute on an unstructured workfile for k-means clustering add-in"
endif

'***************************************
' *** SETUP WORKFILE PAGE ***
'***************************************

' create a new workfile page to execute work on
%page_work = @getnextname("scratch")
while 1 
	
	' if the name generated is not a workfile page, create the working page with this name
	if @pageexist(%page_work) = 0 then
		pagecreate(page={%page_work}) {%FREQ} {%SMPL}
		exitloop
	' if the name generated is a workfile page, append a 0 to the end of the name and reiterate to see if it exists
	else
		%page_work = %page_work + "0"
	endif
wend

for %srs {%SERIES}
	' 1) move the series to the  working page
	copy {%PAGE_CALLED}\{%srs} {%page_work}\{%srs}

	' 2) impute series (if requested)
	if !IMPUTE then
		{%srs}.ipolate(type=lin) {%srs}_dlt
		delete {%srs}
		rename {%srs}_dlt {%srs}
	endif

	' 3) normalize the series (to prevent differently scaled series from having disproportionate impacts on cluster centroids)
	{%srs} = ({%srs} - @mean({%srs})) / @stdev({%srs})	
next
pageselect {%page_work}

' create a matrix housing the series (dropping any obs with NAs)
%g_srs = @getnextname("g_srs")
	group {%g_srs} {%SERIES}
%m_srs = @getnextname("m_srs")
	stom({%g_srs}, {%m_srs})

{%m_srs}.setcollabels {%SERIES}
' figure out which rows correspond to which observations in the group of series & reset matrix labels accordingly
%complete_idxs = ""
for !row = 1 to @rows({%g_srs})
	!complete_idx = 1 
	for %srs {%SERIES}
		if {%srs}(!row) = NA then
			!complete_idx = 0
			exitloop
		endif
	next
	
	if !complete_idx then
		%complete_idxs = %complete_idxs + " " + @str(!row)
	endif
next
{%m_srs}.setrowlabels {%complete_idxs}
delete {%g_srs}

' throw an error if the # of clusters is greater than or equal to the # of observations
!obs = @rows({%m_srs})
if !K >= !obs then
	seterr "ERROR: there are at least as many clusters as there are complete observations"
endif

' remove the observation's series values into their own vector
for !obs = 1 to @rows({%m_srs})
	%obs = "v_obs" + @str(!obs)
	 ' extract the observation's values
	vector {%obs} = {%m_srs}.@row(!obs)
next

' figure out which observations will be randomly initialized as centroids for each iteration of k-means to be done
%m_init = @getnextname("m_init")
matrix(!K, !ITERS) {%m_init}
%vec_prev = "" ' tests equality when iterated onto the next vector
for !iter = 1 to !ITERS
	%vec = @getnextname("v_idxs")
	vector(@rows({%m_srs})) {%vec} = NA
	' fill in the k-means iteration's vector where each element is the vector's index
	for !obs_iter = 1 to @rows({%m_srs})
		{%vec}(!obs_iter) = !obs_iter
	next
	' scatter the vector's entries (set a seed to ensure reproducibility)
	rndseed !iter
	{%vec} = @permute({%vec})
	' drop the rows not in the top !K (not sure how to do this quicker)
	for !row_drop = (!K + 1) to @rows({%m_srs})
		!row_drop0 = @rows({%m_srs}) + (!K + 1) - !row_drop ' drop ending elements first to not disrupt indexing
		{%vec} = {%vec}.@droprow(!row_drop0)
	next
	' sort to more easily compare different initialization indices
	{%vec} = @sort({%vec})
	' place the iteration's initialized centroid observations into the appropriate initialization matrix column
	colplace({%m_init}, {%vec}, !iter)
	delete {%vec}
next

'**************************************************
' *** EXECUTE K-MEANS CLUSTERING ***
'**************************************************
logmsg
logmsg ----- Executing k-means clustering with !K clusters over !ITERS iterations
logmsg

' initialize the cost variable to be minimized 
!cost_min = NA 
' execute k-means clustering across each iteration
for !iter = 1 to !ITERS
	' extract centroids from the respective randomly initialized matrix column	
	%centr_idxs = @getnextname("v_centr_idxs")
	vector {%centr_idxs} = {%m_init}.@col(!iter)
	' create k vectors with the initialized indexed coordinates
	for !centr = 1 to !K
		!centr_idx = {%centr_idxs}(!centr)
		%centr = "v_centr" + @str(!centr) + "_old"
		vector {%centr} = {%m_srs}.@row(!centr_idx)
	next
	delete {%centr_idxs}

	' only exit while loop when the clusters have reached their optima
	while 1

		' iterate through each observation & find its closest centroid
		%centrs = @wlookup("v_centr*old", "vector")
		for !obs = 1 to @rows({%m_srs})
			%obs = "v_obs" + @str(!obs)
			'  find the centroid the observation is closest to
			!min_dist = NA
			for %centr {%centrs} 
				!dist = @sqrt(@sum(@epow({%obs} - {%centr}, 2)))
				' if this centroid is the closest centroid so far, take note
				if !min_dist = NA or !dist < !min_dist then
					!min_dist = !dist
					%min_centr = %centr
				endif
			next 
			' indicate in the obs' closest centroid that this obs is closest to particular centroid
			%assoc_obs = {%min_centr}.@attr("assoc_obs")
			%assoc_obs = %assoc_obs + " " + @str(!obs)
			{%min_centr}.setattr("assoc_obs") %assoc_obs
		next 
	
		' go thru each cluster centroid & recalculate it as the mean of each of the newest closest centroids
		for %centr {%centrs}
			%assoc_obs = {%centr}.@attr("assoc_obs")
			!clust_num = @wcount(%assoc_obs)
			%m_centr = @replace(%centr, "V_", "M_")
			' initialize the cluster's matrix of current associated points
			matrix(!clust_num, @columns({%m_srs})) {%m_centr} = NA
			!clust_row = 1
			' fill the cluster's matrix with its observations
			for %closest_clust {%assoc_obs}
				!closest_clust = @val(%closest_clust)
				vector v_temp = {%m_srs}.@row(!closest_clust)
				rowplace({%m_centr}, @transpose(v_temp), !clust_row) 
				delete v_temp
				!clust_row = !clust_row + 1
			next
			' take the mean of the cluster's series
			%centr_new = @replace(%centr, "_OLD", "_NEW")
			vector {%centr_new} = @cmean({%m_centr})
		next

		' determine if it definitively can be concluded that an optimum is reached
		!optimum_reached = 1
		%centrs_old = @wlookup("v_centr*_old", "vector")
		for %centr_old {%centrs_old}
			%centr_new = @replace(%centr_old, "_OLD", "_NEW")
			if {%centr_old} <> {%centr_new} then
				!optimum_reached = 0
				exitloop
			endif
		next		
		if !optimum_reached then
			delete v_centr*_new ' don't need this anymore - just used them to verify that cluster solution converged
			' calculate the cost function of the solution
			!cost_iter = 0
			%centrs = @wlookup("v_centr*_old", "vector")
			for %centr {%centrs}
				%clust_obs = {%centr}.@attr("assoc_obs")
				for %clust_ob {%clust_obs}
					%clust_ob = "v_obs" + %clust_ob
					!clust_cost = @sum(@epow({%clust_ob} - {%centr}, 2))
					!cost_iter = !cost_iter + !clust_cost
				next
			next 
			!cost_iter = !cost_iter / @rows({%m_srs})
			' if this cost function is less than the previous best (or on the 1st iteration), store these centroids as the optimal ones thus far
			if !cost_min = NA or !cost_iter < !cost_min then
				!cost_min = !cost_iter
				' clear out the previous optimal vectors & rename the current iterated 1s
				if @wcount(@wlookup("v_centr*_opt", "vector")) > 0 then
					delete v_centr*_opt 
				endif 
				rename v_centr*_old v_centr*_opt
				delete m_centr*_old ' just need the coordinates at this point
			endif 
			exitloop 
		' if optimal clustering is not achieved, prep for another iteration
		else
			delete m_centr*_old v_centr*_old
			rename v_centr*_new v_centr*_old
		endif
	wend ' next move of current cluster centroids
next ' next random init of cluster centeroids

' ************************************************
' *** CLEAN UP & PRESENT RESULTS ***
' ************************************************
logmsg
logmsg ----- Presenting results & cleaning up
logmsg

' NOTE: all cluster summary stats are recalculated, because the calculations were done on normalized series to avoid scaling issues

' all that is needed at this juncture from the above work is:
' i) the closest observations to each cluster centroid
' ii) the indices of observations used in the cluster analysis (excludes observations where any included series has an NA)

%concepts = {%m_srs}.@collabels ' ordering of series for cluster centroid coordinates 
%obs_idxs = {%m_srs}.@rowlabels ' indices of used observations

' create a text file to present the results
pageselect {%PAGE_CALLED}
%results = @getnextname("kmeans_results")
text {%results}
{%results}.append "*******************************************************************"
{%results}.append "*** ANALYSIS OF K-MEANS CLUSTERING RESULTS ***"
{%results}.append "*******************************************************************"
{%results}.append
{%results}.append "******************************************************************************************"
{%results}.append " *** USER SELECTED PARAMETERS ***"
{%results}.append
%k_num_msg = "# of clusters: " + @str(!K)
	{%results}.append %k_num_msg
%iter_msg = "# of iterations used: " + @str(!ITERS)
	{%results}.append %iter_msg
' place a comma between each series for presentation's sake
%concept_list = ""
for %concept {%concepts}
	%concept_list = %concept_list + " " + %concept + ","
next
%concept_list = @left(%concept_list, @len(%concept_list) - 1) ' strike the last comma
%srs_msg = "Series included in clusters: " + %concept_list
	{%results}.append %srs_msg
{%results}.append "******************************************************************************************"
{%results}.append

' calculate the means of the series for all observations used in the cluster analysis (obs indices with NAs are dropped)
for %concept {%concepts}
	!{%concept}_all_sum = 0
	for %obs_idx {%obs_idxs}
		!{%concept}_all_sum = !{%concept}_all_sum + {%concept}(@val(%obs_idx))
	next
	!{%concept}_all_mean = !{%concept}_all_sum / @wcount(%obs_idxs)
next

' iterate thru each cluster centroid
pageselect {%page_work}
series clusternum
for !i = 1 to !K
	pageselect {%page_work}
	%centr_opt = "v_centr" + @str(!i) + "_opt"
	%assoc_obs = {%centr_opt}.@attr("assoc_obs")
	' append the cluster's id info to the outputted text file
	pageselect {%PAGE_CALLED}
	{%results}.append "******************************************************************************************"
	%k_msg = "CLUSTER " + @str(!i) + ":"
		{%results}.append %k_msg
	{%results}.append
	' append the observations that belong to the cluster in the outputted text file with assoc_obs_dates string
	%assoc_obs_dates = ""
	' iterate thru each concept & place statistics for that cluster compared to the general mean
	for %concept {%concepts}
		!{%concept}_k_sum = 0
		for %assoc_ob {%assoc_obs}
			' must find out which index this associated observation actually is (can be offset by NAs)
			!assoc_ob = @val(@word(%obs_idxs, @val(%assoc_ob)))	
			%assoc_obs_dates = %assoc_obs_dates + " " + @otod(!assoc_ob) + ","
			pageselect {%page_work}
			clusternum(!assoc_ob) = !I
			pageselect {%page_called}
			' add centroid's associated observation to the accumulator
			!{%concept}_k_sum = !{%concept}_k_sum + {%concept}(!assoc_ob)
		next
		' only append the periods associated with the cluster if this is the 1st concept iteration
		if @wfind(%concepts, %concept) = 1 then
			{%results}.append "Observations Included in Cluster:"
			%assoc_obs_dates = @left(%assoc_obs_dates, @len(%assoc_obs_dates) - 1) ' drop the final comma
				{%results}.append %assoc_obs_dates
			{%results}.append
		endif
		' calculate the concept's mean across this cluster
		!{%concept}_k_mean = !{%concept}_k_sum / @wcount(%assoc_obs)
		' calculate how much greater this concept's cluster mean is than the total mean
		!{%concept}_k_abs_diff = !{%concept}_k_mean - !{%concept}_all_mean
		' calculate the percent increase of this cluster's concept mean than the total mean (so long as the all obs concept mean is not 0)
		if !{%concept}_all_mean <> 0 then
			!{%concept}_k_pct_diff = (!{%concept}_k_mean - !{%concept}_all_mean) / !{%concept}_all_mean
		endif
		' round message concepts to the 1000th place & place in a scalar name with no nested string (cannot convert to string if a program variable is nested within the scalar's definition)
		!concept_k_mean = @round(1000 * !{%concept}_k_mean) / 1000
		' append the mean of this concept for this centroid to the log message
		%k_concept_msg = %concept + " cluster average is: " + @str(!concept_k_mean)
			{%results}.append %k_concept_msg
		!abs_diff = @round(1000 * !{%concept}_k_abs_diff) / 1000
		!pct_diff = @round(1000 * !{%concept}_k_pct_diff) / 1000
		if !abs_diff >= 0 then 
			%abs_diff_msg = "    i) " + @str(@abs(!abs_diff)) + " units greater than overall " + %concept + " mean"
			%pct_diff_msg = "    ii) " + @str(@abs(!pct_diff)) + "% greater than overall " + %concept + " mean" 
		else
			%abs_diff_msg = "    i) " + @str(@abs(!abs_diff)) + " units less than overall " + %concept + " mean"
			%pct_diff_msg = "    ii) " + @str(@abs(!pct_diff)) + "% less than overall " + %concept + " mean" 
		endif
		{%results}.append %abs_diff_msg 	
		{%results}.append %pct_diff_msg
		{%results}.append
		
		pageselect {%page_work}
		series {%concept}_{!i} = @recode(clusternum={!i}, {%concept}, NA)
		pageselect {%page_called}
	next 
	{%results}.append "******************************************************************************************"
	{%results}.append 
	
	
next 

' present the final results to the user


'graph
pageselect {%page_work}
%stackname = %page_work + "_STK"
!count = 0
while @pageexist(%stackname)
	%stackname = %page_work + "_STK" + "_" + @str(!count,"g02")
wend
pagestack(?=stk, page={%stackname}) {%concept}_? @ *_?
group g_stk *_stk
freeze(gr_kmeans) g_stk.scat(mult=l,panel=combine)



pageselect {%PAGE_CALLED}
copy {%page_work}\clusternum {%page_called}\
%graphname = @getnextname("gr_kmeans")
copy {%stackname}\gr_kmeans {%page_called}\{%graphname}
pagedelete {%stackname}

pageselect {%page_called}
show {%results}
show {%graphname}


