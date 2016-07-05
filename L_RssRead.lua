module("L_RssRead", package.seeall)

RSSREAD_SERVICE = "urn:demo-micasaverde-com:serviceId:RssRead1"
local DEVICE_ID
local PARENT_DEVICE
local DEVICE_TYPE = "urn:demo-micasaverde-com:device:RssReader:1"
local TEMPERATURE_SERVICE = "urn:upnp-org:serviceId:TemperatureSensor1"
local BAR_SERVICE = "urn:upnp-org:serviceId:Barometer1"
local WIND_SERVICE = "urn:upnp-org:serviceId:WindSensor1"
local HADEVICE_SERVICE = "urn:micasaverde-com:serviceId:HaDevice1"
local HUMIDITY_SERVICE = "urn:micasaverde-com:serviceId:HumiditySensor1"
local MSG_CLASS = "RssRead"

local DEBUG_MODE = true
local taskHandle = -1

local TASK_ERROR = 2
local TASK_ERROR_PERM = -2
local TASK_SUCCESS = 4
local TASK_BUSY = 1

local function log(text, level)
	luup.log(string.format("%s: %s", MSG_CLASS, text), (level or 50))
end

local function debug(text)
	if (DEBUG_MODE) then
		log("debug: " .. text, 35)
	end
end

local function task(text, mode)
	luup.log("task " .. text)
	if (mode == TASK_ERROR_PERM) then
		taskHandle = luup.task(text, TASK_ERROR, MSG_CLASS, taskHandle)
	else
		taskHandle = luup.task(text, mode, MSG_CLASS, taskHandle)

		-- Clear the previous error, since they're all transient
		if (mode ~= TASK_SUCCESS) then
			luup.call_delay("clearTask", 30, "", false)
		end
	end
end

--
-- Has to be "non-local" in order for MiOS to call it
--
function clearTask()
	task("Clearing...", TASK_SUCCESS)
end



function setIfChanged(serviceId, name, value, deviceId, default)
	local curValue = luup.variable_get(serviceId, name, deviceId)

	if ((value ~= curValue) or (curValue == nil)) then
		luup.variable_set(serviceId, name, value, deviceId)
		return true
	else
		return (default or false)
	end
end

--- Find the named Child device of [this] Device.
--
-- This function will enumerate the Master/Global list of devices in Vera and
-- locate the "named" Child device.  It's used all over to locate the Children.
--
--   "Why haven't you checked the children"  :)
--
-- This would make an awfully handy convenience method on a Device object... hint, hint.
--
function findChild(parentDevice, label)
	for k, v in pairs(luup.devices) do
		if (v.device_num_parent == parentDevice
			and v.id == label) then
			return k
		end
	end

	-- Dump a copy of the Global Module list for debugging purposes.
	log("findChild cannot find parentDevice: " .. tostring(parentDevice) .. " label: " .. label)
	for k, v in pairs(luup.devices) do
		log("Device Number: " .. k ..
			" v.device_type: " .. tostring(v.device_type) ..
			" v.device_num_parent: " .. tostring(v.device_num_parent) ..
			" v.id: " .. tostring(v.id)
		)
	end
end


-- string operations
function ltrim(s)
  return (s:gsub("^%s*", ""))
end
function trim1(s)
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end	

-- xml parsing 
-----------------------------------------------------------------------------------------
-- LUA only XmlParser from Alexander Makeev
-----------------------------------------------------------------------------------------
XmlParser = {};

function XmlParser:ToXmlString(value)
	value = string.gsub (value, "&", "&amp;");		-- '&' -> "&amp;"
	value = string.gsub (value, "<", "&lt;");		-- '<' -> "&lt;"
	value = string.gsub (value, ">", "&gt;");		-- '>' -> "&gt;"
	--value = string.gsub (value, "'", "&apos;");	-- '\'' -> "&apos;"
	value = string.gsub (value, "\"", "&quot;");	-- '"' -> "&quot;"
	-- replace non printable char -> "&#xD;"
	value = string.gsub(value, "([^%w%&%;%p%\t% ])",
		function (c) 
			return string.format("&#x%X;", string.byte(c)) 
			--return string.format("&#x%02X;", string.byte(c)) 
			--return string.format("&#%02d;", string.byte(c)) 
		end);
	return value;
end

function XmlParser:FromXmlString(value)
	value = string.gsub(value, "&#x([%x]+)%;",
		function(h) 
			return string.char(tonumber(h,16)) 
		end);
	value = string.gsub(value, "&#([0-9]+)%;",
		function(h) 
			return string.char(tonumber(h,10)) 
		end);
	value = string.gsub (value, "&quot;", "\"");
	value = string.gsub (value, "&apos;", "'");
	value = string.gsub (value, "&gt;", ">");
	value = string.gsub (value, "&lt;", "<");
	value = string.gsub (value, "&amp;", "&");
	return value;
end
   
function XmlParser:ParseArgs(s)
  local arg = {}
  string.gsub(s, "(%w+)=([\"'])(.-)%2", function (w, _, a)
		arg[w] = self:FromXmlString(a);
	end)
  return arg
end

function XmlParser:ParseXmlText(xmlText)
  local stack = {}
  local top = {Name=nil,Value=nil,Attributes={},ChildNodes={}}
  table.insert(stack, top)
  local ni,c,label,xarg, empty
  local i, j = 1, 1
  while true do
	ni,j,c,label,xarg, empty = string.find(xmlText, "<(%/?)([%w:]+)(.-)(%/?)>", i)
	if not ni then break end
	-- start APY 18.11.2014
	-- get CDATA if exists
	local text, ci, bcdata
	local cdata = ltrim(string.sub(xmlText, j+1))
	if  string.match(cdata,"^<!%[CDATA%[") then
	  ci = string.find(xmlText, "]]", j)
	  if not ci then
		error("XmlParser: CDATA is not closed correctly")
	   else
		 text= trim1(string.gsub(string.sub(xmlText, j+1, ci-1),"<!%[CDATA%[",""))
		 j = ci
	   end
	   bcdata = true
	else
	  text = string.sub(xmlText, i, ni-1)
	  bcdata = false
	end
	--local text = string.sub(xmlText, i, ni-1);
	-- end APY 18.11.2014
	if not string.find(text, "^%s*$") then
	  if not top.Value then -- APY 18.11.2014
		top.Value=(top.Value or "")..self:FromXmlString(text);
	  end -- APY 18.11.2014
	end
	if empty == "/" then  -- empty element tag
	  table.insert(top.ChildNodes, {Name=label,Value=nil,Attributes=self:ParseArgs(xarg),ChildNodes={}})
	elseif c == "" then   -- start tag
	  top = {Name=label, Value=nil, Attributes=self:ParseArgs(xarg), ChildNodes={}}
	  -- start APY 18.11.2014
	  if bcdata then
		if not string.find(text, "^%s*$") then
		  top.Value=(top.Value or "")..self:FromXmlString(text);
		end
	  end 
	  -- end APY 18.11.2014	  
	  table.insert(stack, top)   -- new level
	  --log("openTag ="..top.Name);
	else  -- end tag
	  local toclose = table.remove(stack)  -- remove top
	  --log("closeTag="..toclose.Name);
	  top = stack[#stack]
	  if #stack < 1 then
		error("XmlParser: nothing to close with "..label)
	  end
	  if toclose.Name ~= label then
		error("XmlParser: trying to close "..toclose.Name.." with "..label)
	  end
	  table.insert(top.ChildNodes, toclose)
	end
	i = j+1
  end
  local text = string.sub(xmlText, i);
  if not string.find(text, "^%s*$") then
	  stack[#stack].Value=(stack[#stack].Value or "")..self:FromXmlString(text);
  end
  if #stack > 1 then
	error("XmlParser: unclosed "..stack[stack.n].Name)
  end
  return stack[1].ChildNodes[1];
end

function XmlParser:ParseXmlFile(xmlFileName)
	local hFile,err = io.open(xmlFileName,"r");
	if (not err) then
		local xmlText=hFile:read("*a"); -- read file content
		io.close(hFile);
		return self:ParseXmlText(xmlText),nil;
	else
		return nil,err;
	end
end
------------------------------------------------------------------------------------------

function dump(_class, no_func, depth)
	if(not _class) then 
		--luup.log("nil");
		return;
	end
	
	if(depth==nil) then depth=0; end
	local str="";
	for n=0,depth,1 do
		str=str.."\t";
	end
	
	--luup.log(str.."["..type(_class).."]");
	--luup.log(str.."{");
	
	for i,field in pairs(_class) do
		if(type(field)=="table") then
			--luup.log(str.."\t"..tostring(i).." =");
			dump(field, no_func, depth+1);
		else 
			if(type(field)=="number") then
				--luup.log(str.."\t"..tostring(i).."="..field);
			elseif(type(field) == "string") then
				--luup.log(str.."\t"..tostring(i).."=".."\""..field.."\"");
			elseif(type(field) == "boolean") then
				--luup.log(str.."\t"..tostring(i).."=".."\""..tostring(field).."\"");
			else
				if(not no_func)then
					if(type(field)=="function")then
						--luup.log(str.."\t"..tostring(i).."()");
					else
						--luup.log(str.."\t"..tostring(i).."<userdata=["..type(field).."]>");
					end
				end
			end
		end
	end
	--luup.log(str.."}");
end

-- returns first node from nodetree with name nodename
function f_return_subnode(x_nodetree, x_nodename)
  local i,xmlNode
  for i,xmlNode in pairs(x_nodetree.ChildNodes) do
    if(xmlNode.Name == x_nodename) then
	  return xmlNode
	end
  end
end

-- returns all node from nodetree with name nodename
function f_return_subnodes(x_nodetree, x_nodename)
  local xmlnodes, i, xmlNode
  xmlnodes = {}
  for i,xmlNode in pairs(x_nodetree.ChildNodes) do
    if(xmlNode.Name == x_nodename) then
	  table.insert(xmlnodes, xmlNode)
	end
  end
  return xmlnodes
end

function f_get_node_attr_val(x_node, x_attr_name)
  for key,attr in pairs(x_node.Attributes) do
    if key == x_attr_name then
	  return attr
    end
  end
end

function print_val(x_node)
  if(x_node.Value) then
    luup.log(x_node.Name .. " val=\""..x_node.Value.."\"");
  end
  for key,attr in pairs(x_node.Attributes) do
    luup.log("att_name=\""..key.."\" att_value=\""..attr.."\"");
  end
end

-- keys define data, to obtain
-- xy_user_params {
--                   temperature = {}
--			         humidity = {}
--                }   
-- 
--                sensor = {id=nil, attr=nil, value=nil, unit=nil } 
--
--
  
function sendRequest(xUrl, xUser, xPass, xy_user_params, xSelected)
	  
	local yTitle, yDescr, yContent, yLink, yCount
	local sensor
	-- rss request for xml
	-- http://192.168.1.15/weather/wxrss.xml
	-- guest
	-- guest
	local status, xml = luup.inet.wget(xUrl, 5, xUser, xPass)
	if (status ~= 0) then
	    log("luup.inet.wget - status: " .. status)
		return
	end
	local xmlTree=XmlParser:ParseXmlText(xml)
	-- get channel node
	local channelnode = f_return_subnode(xmlTree,"channel")
	if channelnode == nil then
		luup.log("Channel node does not exist")
		return
	end
	-- get item 1..N
	local itemnodes = f_return_subnodes(channelnode,"item")
	if itemnodes == nil then
		luup.log("Item nodes do not exist")
		return
	end
	yCount = table.getn(itemnodes)
	for i,xmlnode in pairs (itemnodes) do
	    if i == xSelected then
			local lnode = f_return_subnode(xmlnode,"title")
			yTitle = lnode.Value
			lnode = f_return_subnode(xmlnode,"description")
			yDescr = lnode.Value
			lnode = f_return_subnode(xmlnode,"link")
			yLink = lnode.Value
			lnode = f_return_subnode(xmlnode,"content")
			if lnode then
			  yContent = lnode.Value
			end 
			if xy_user_params ~= nil then
				for key,param in pairs(xy_user_params) do
					lnode = f_return_subnode(xmlnode,key)
					-- get configuration params
					if lnode ~= nil then
						sensornodes = f_return_subnodes(lnode,"sensor")
						for i,sensornode in pairs(sensornodes) do
							sensor = {id=nil, attr=nil, value=nil, unit=nil}
							sensor.id = f_get_node_attr_val(sensornode,"id")
							sensor.attr = f_get_node_attr_val(sensornode,"attr")
							--print_val(sensornode)
							nodevalue = f_return_subnode(sensornode,"value")
							nodeunit = f_return_subnode(sensornode,"unit")
							--print_val(nodevalue)
							--print_val(nodeunit)
							sensor.value = nodevalue.Value
							sensor.unit = nodeunit.Value
							table.insert(xy_user_params[key],sensor)
						end
						
					end
					
				end
				break
			end
		end
	end
	dump(xmlTree)
    collectgarbage("collect")
	return yTitle, yDescr, yContent, yLink, yCount, xy_user_params
end


function refreshCache()
	--
	-- And some test code that call's WUI's [unofficial] Weather API/URL/
	--
	-- Many thanks to the recommendations of both @LibraSun and @Ap15e from
	-- the micasaverde.com forums for providing various pointers to alternative
	-- Weather services.
	--
	debug("refreshCache called")
	--

	-- Default the refresh period to 30 minutes (1800s), but read it's value from the
	-- "period" variable.  No sense to have it  less then 10 sec 
	--
	local period = luup.variable_get(RSSREAD_SERVICE, "refreshperiod", PARENT_DEVICE)
	period = tonumber(period)
	
	debug("period 1: " .. tostring(period))
	if (period == nil or (period ~= 0 and period < 10) or period > 3600) then
		period = 1800
	end

	--
	-- Resubmit the refreshCache job, unless the period==0 (disabled/manual)
	--
	debug("period 2: " .. tostring(period))
	if (period ~=0) then
	    debug("timer for refreshVariables set in " .. tostring(period))
		luup.call_timer("refreshVariables", 1, tostring(period), "")
	end

	--
	-- If the Location override is set, use it's value, otherwise we'll format a string 
	-- using the Lat/Long that Vera Provides.
	-- We pre-process the user-provided string to pseudo URL-Encode the Value.
	--
	
	local weather = luup.variable_get(RSSREAD_SERVICE, "weatherItem", PARENT_DEVICE)
	
	local lurl = luup.variable_get(RSSREAD_SERVICE, "rssURL", PARENT_DEVICE)
	local lusername = luup.variable_get(RSSREAD_SERVICE, "userName", PARENT_DEVICE)
	local lpassword = luup.variable_get(RSSREAD_SERVICE, "Password", PARENT_DEVICE) 
	local lselected = luup.variable_get(RSSREAD_SERVICE, "selectedItem", PARENT_DEVICE) 
	lselected = tonumber(lselected)
	
	local title, descr, content, link, lcount, user_params
	if weather == "1" then
	  user_params = { temperature= {}, humidity ={}, pressure ={}, windspeed ={}, winddirection ={} }
	end
	--"http://192.168.1.15/weather/wxrss.xml","guest","guest"
	title, descr, content, link, lcount, user_params = sendRequest(lurl,lusername,lpassword,user_params,lselected)	

	if (title) then
	  debug("refreshCache: Successful execution of RSS call")
	  local changed = false

	  -- parent device variables
	  changed = setIfChanged(RSSREAD_SERVICE, "rssTitle", title,
						     PARENT_DEVICE, changed)
							 
	  changed = setIfChanged(RSSREAD_SERVICE, "rssDescription", descr,
						     PARENT_DEVICE, changed)	
							 
	  changed = setIfChanged(RSSREAD_SERVICE, "rssContent", content,
						     PARENT_DEVICE, changed)	

	  changed = setIfChanged(RSSREAD_SERVICE, "rssLink", link,
						     PARENT_DEVICE, changed)

	  changed = setIfChanged(RSSREAD_SERVICE, "itemsCount", lcount,
						     PARENT_DEVICE, changed)								 
	  
	  if weather == "1" then
		  if table.getn(user_params.temperature) > 0 then	  
			  -- Store the current temperature
			  changed = setIfChanged(TEMPERATURE_SERVICE, "CurrentTemperature", user_params.temperature[1].value,
									 CURRENT_TEMPERATURE_DEVICE_IN, changed)

			  -- Store the current temperature
			  changed = setIfChanged(TEMPERATURE_SERVICE, "CurrentTemperature", user_params.temperature[2].value,
									 CURRENT_TEMPERATURE_DEVICE_OUT, changed)
		  end
		  if table.getn(user_params.humidity) > 0 then
			  -- Store the current humidity
			  changed = setIfChanged(HUMIDITY_SERVICE, "CurrentLevel", user_params.humidity[1].value,
									 CURRENT_HUMIDITY_DEVICE_IN, changed)

			  -- Store the current humidity
			  changed = setIfChanged(HUMIDITY_SERVICE, "CurrentLevel", user_params.humidity[2].value,
									 CURRENT_HUMIDITY_DEVICE_OUT, changed)							 
		   end
		   
		  if table.getn(user_params.pressure) > 0 then
			  -- Store the current pressure
			  changed = setIfChanged(BAR_SERVICE, "CurrentAirPressure", user_params.pressure[1].value,
									 CURRENT_PRESSURE_DEVICE, changed)
							 
		   end	   

		  if table.getn(user_params.windspeed) > 0 then
			  -- Store the current pressure
			  changed = setIfChanged(WIND_SERVICE, "WindSpeed", user_params.windspeed[1].value,
									 CURRENT_WIND_DEVICE, changed)
							 
		   end	

		  if table.getn(user_params.winddirection) > 0 then
			  -- Store the current pressure
			  changed = setIfChanged(WIND_SERVICE, "WindDirection", user_params.winddirection[1].value,
									 CURRENT_WIND_DEVICE, changed)
							 
		   end		   
	  end

	  -- Store the last update time according to the Weather feed itself (using the WEATHER_SERVICE SID)
	  -- changed = setIfChanged(WEATHER_SERVICE, "LastUpdate", result.epoch, PARENT_DEVICE, changed)

	  if (changed) then
		  -- Store the current timestamp, using the HADEVICE SID
		  changed = setIfChanged(HADEVICE_SERVICE, "LastUpdate", os.time(), PARENT_DEVICE, changed)
	  end
	else
	  log("Problem calling URL")
	end
end



function startupDeferred()
	local url = luup.variable_get(RSSREAD_SERVICE, "rssURL", PARENT_DEVICE)
	if (url == nil or url == "" ) then
		--
		-- Set the variable so that it appears in the Device/Advanced list
		--
		luup.variable_set(RSSREAD_SERVICE, "rssURL", "", PARENT_DEVICE)
		luup.variable_set(RSSREAD_SERVICE, "userName", "", PARENT_DEVICE)
		luup.variable_set(RSSREAD_SERVICE, "Password", "", PARENT_DEVICE)

		local msg = "URL of RSS feed has to be defined.  Set in Dialog, and Save/Reload."
		task(msg, TASK_ERROR_PERM)
		return
	end
	local weather = luup.variable_get(RSSREAD_SERVICE, "weatherItem", PARENT_DEVICE)
	if (weather == nil or weather == "") then

		local msg = "Set weather RSS support weather items"
		task(msg, TASK_ERROR_PERM)
		return
	end
    
	-- TODO: ping url, whether it reponds or not and wether it needs authentification or not
	-- ping
    luup.call_timer("refreshVariables", 1, "1", "")
	
end

function initialize(parentDevice)
    PARENT_DEVICE = parentDevice
    local weather = luup.variable_get(RSSREAD_SERVICE, "weatherItem", PARENT_DEVICE)
	
	local CURRENT_TEMPERATURE_ID_IN = "Inside-Temperature"
	local CURRENT_TEMPERATURE_ID_OUT = "Outside-Temperature"
	local CURRENT_HUMIDITY_ID_IN = "Inside-Humidity"
	local CURRENT_HUMIDITY_ID_OUT = "Outside-Humidity"
	local CURRENT_PRESSURE_ID="Pressure"
	local CURRENT_WIND_ID="Wind"

	log("#" .. tostring(parentDevice) .. " starting up with id " .. luup.devices[parentDevice].id)

	--
	-- Build child devices for each type of metric we're gathering from Oregon Weather station RSS.
	-- At this point that's:
	--     Weather-Current-Temperature - the last reported Temperature at your location
	--     Weather-Current-Humidity - the last reported Humidity Level at your location
	--
	if weather == "1" then
		local childDevices = luup.chdev.start(parentDevice)

		luup.chdev.append(parentDevice, childDevices,
			CURRENT_TEMPERATURE_ID_IN, "Oregon inside Temperature",
			"urn:schemas-micasaverde-com:device:TemperatureSensor:1", "D_TemperatureSensor1.xml",
			"S_TemperatureSensor1.xml", "", true)

		luup.chdev.append(parentDevice, childDevices,
			CURRENT_TEMPERATURE_ID_OUT, "Oregon outside Temperature",
			"urn:schemas-micasaverde-com:device:TemperatureSensor:1", "D_TemperatureSensor1.xml",
			"S_TemperatureSensor1.xml", "", true)		

		luup.chdev.append(parentDevice, childDevices,
			CURRENT_HUMIDITY_ID_IN, "Oregon inside Humidity",
			"urn:schemas-micasaverde-com:device:HumiditySensor:1", "D_HumiditySensor1.xml",
			"S_HumiditySensor1.xml", "", true)
			
		luup.chdev.append(parentDevice, childDevices,
			CURRENT_HUMIDITY_ID_OUT, "Oregon outisde Humidity",
			"urn:schemas-micasaverde-com:device:HumiditySensor:1", "D_HumiditySensor1.xml",
			"S_HumiditySensor1.xml", "", true)		

		luup.chdev.append(parentDevice, childDevices,
			CURRENT_PRESSURE_ID, "Oregon barometer",
			"urn:schemas-micasaverde-com:device:Barometer:1", "D_Barometer1.xml",
			"S_Barometer1.xml", "", true)		

		luup.chdev.append(parentDevice, childDevices,
			CURRENT_WIND_ID, "Oregon anemometer",
			"urn:schemas-micasaverde-com:device:WindSensor:1", "D_WindSensor1.xml",
			"S_WindSensor1.xml", "", true)		

		luup.chdev.sync(parentDevice, childDevices)

		--
		-- Note these are "pass-by-Global" values that refreshCache will later use.
		-- I need a var-args version of luup.call_timer(...) to pass these in a
		-- cleaner manner.
		--

		
		CURRENT_TEMPERATURE_DEVICE_IN = findChild(parentDevice, CURRENT_TEMPERATURE_ID_IN )
		CURRENT_TEMPERATURE_DEVICE_OUT = findChild(parentDevice,CURRENT_TEMPERATURE_ID_OUT)
		CURRENT_HUMIDITY_DEVICE_IN = findChild(parentDevice, CURRENT_HUMIDITY_ID_IN)
		CURRENT_HUMIDITY_DEVICE_OUT = findChild(parentDevice, CURRENT_HUMIDITY_ID_OUT)
		
		CURRENT_PRESSURE_DEVICE = findChild(parentDevice, CURRENT_PRESSURE_ID)
		CURRENT_WIND_DEVICE = findChild(parentDevice, CURRENT_WIND_ID)
	end

	--
	-- Set variables for rss override, only "set" these if they aren't already set
	-- to force these Variables to appear in Vera's Device list.
	--
	if (luup.variable_get(RSSREAD_SERVICE, "rssURL", parentDevice) == nil) then
		luup.variable_set(RSSREAD_SERVICE, "rssURL", "", parentDevice)
	end

	if (luup.variable_get(RSSREAD_SERVICE, "userName", parentDevice) == nil) then
		luup.variable_set(RSSREAD_SERVICE, "userName", "", parentDevice)
	end	
	if (luup.variable_get(RSSREAD_SERVICE, "Password", parentDevice) == nil) then
		luup.variable_set(RSSREAD_SERVICE, "Password", "", parentDevice)
	end	
	if (luup.variable_get(RSSREAD_SERVICE, "refreshperiod", parentDevice) == nil) then
		luup.variable_set(RSSREAD_SERVICE, "refreshperiod", "", parentDevice)
	end		
	if (luup.variable_get(RSSREAD_SERVICE, "weatherItem", parentDevice) == nil) then
		luup.variable_set(RSSREAD_SERVICE, "weatherItem", "0", parentDevice)
	end		
	if (luup.variable_get(RSSREAD_SERVICE, "selectedItem", parentDevice) == nil) then
		luup.variable_set(RSSREAD_SERVICE, "selectedItem", "1", parentDevice)
	end	


	--
	-- Do this deferred to avoid slowing down startup processes.
	--
	startupDeferred()
end

	
function test()	
	-- calling request
	local title, descr, content, user_params
	user_params = { temperature= {}, humidity ={}, pressure ={} }
	
	title, descr, content,link = sendRequest("http://192.168.1.15/weather/wxrss.xml","guest","guest",user_params,1)
	if not title then
	  return
	end
	luup.log(link)
	luup.log(title)
	luup.log(user_params.temperature[1].value)
	luup.log(user_params.humidity[2].value)
	luup.log(user_params.pressure[1].value)
	user_params = { }
	title, descr, content,link, lcount = sendRequest("http://www.itnews.sk/xml/spravy.rss","","",user_params,3)
	luup.log(link)
	luup.log(lcount)
	local weather = luup.variable_get(RSSREAD_SERVICE, "weatherItem", 188)
	if weather == "1" then
	  luup.log("je 1")
	else
	  luup.log("je 0")
	end
	luup.variable_set(RSSREAD_SERVICE, "weatherItem", "1", 188)
	weather = luup.variable_get(RSSREAD_SERVICE, "weatherItem", 188)
	if weather == "1" then
	  luup.log("je 1")
	else
	  luup.log("je 0")
	end
end	

--test()