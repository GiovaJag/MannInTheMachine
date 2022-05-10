/*
 * Copyright (C) 2021  Mikusch
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

static DynamicHook g_DHookEventKilled;
static DynamicHook g_DHookPassesFilterImpl;

static ArrayList m_justSpawnedVector;

static int g_InternalSpawnPoint = INVALID_ENT_REFERENCE;

void DHooks_Initialize(GameData gamedata)
{
	m_justSpawnedVector = new ArrayList(MaxClients);
	
	CreateDynamicDetour(gamedata, "CTFGCServerSystem::PreClientUpdate", DHookCallback_PreClientUpdate_Pre, DHookCallback_PreClientUpdate_Post);
	CreateDynamicDetour(gamedata, "CPopulationManager::AllocateBots", DHookCallback_AllocateBots_Pre);
	CreateDynamicDetour(gamedata, "CTFBotSpawner::Spawn", DHookCallback_Spawn_Pre);
	CreateDynamicDetour(gamedata, "CWaveSpawnPopulator::Update", _, DHookCallback_WaveSpawnPopulatorUpdate_Post);
	CreateDynamicDetour(gamedata, "CMissionPopulator::UpdateMission", _, DHookCallback_MissionPopulatorUpdateMission_Post);
	CreateDynamicDetour(gamedata, "CTFGameRules::GetTeamAssignmentOverride", DHookCallback_GetTeamAssignmentOverride_Pre, DHookCallback_GetTeamAssignmentOverride_Post);
	CreateDynamicDetour(gamedata, "CTFPlayer::GetLoadoutItem", DHookCallback_GetLoadoutItem_Pre, DHookCallback_GetLoadoutItem_Post);
	
	g_DHookEventKilled = CreateDynamicHook(gamedata, "CTFPlayer::Event_Killed");
	g_DHookPassesFilterImpl = CreateDynamicHook(gamedata, "CBaseFilter::PassesFilterImpl");
}

void DHooks_HookClient(int client)
{
	if (g_DHookEventKilled)
	{
		g_DHookEventKilled.HookEntity(Hook_Pre, client, DHookCallback_EventKilled_Pre);
		g_DHookEventKilled.HookEntity(Hook_Post, client, DHookCallback_EventKilled_Post);
	}
}

void DHooks_OnEntityCreated(int entity, const char[] classname)
{
	if (StrEqual(classname, "filter_tf_bot_has_tag"))
	{
		g_DHookPassesFilterImpl.HookEntity(Hook_Pre, entity, DHookCallback_PassesFilterImpl_Pre);
	}
}

static void CreateDynamicDetour(GameData gamedata, const char[] name, DHookCallback callbackPre = INVALID_FUNCTION, DHookCallback callbackPost = INVALID_FUNCTION)
{
	DynamicDetour detour = DynamicDetour.FromConf(gamedata, name);
	if (detour)
	{
		if (callbackPre != INVALID_FUNCTION)
			detour.Enable(Hook_Pre, callbackPre);
		
		if (callbackPost != INVALID_FUNCTION)
			detour.Enable(Hook_Post, callbackPost);
	}
	else
	{
		LogError("Failed to create detour setup handle for %s", name);
	}
}

static DynamicHook CreateDynamicHook(GameData gamedata, const char[] name)
{
	DynamicHook hook = DynamicHook.FromConf(gamedata, name);
	if (!hook)
		LogError("Failed to create hook setup handle for %s", name);
	
	return hook;
}

public MRESReturn DHookCallback_PreClientUpdate_Pre()
{
	// Allows us to have an MvM server with 32 visible player slots
	GameRules_SetProp("m_bPlayingMannVsMachine", false);
	
	return MRES_Handled;
}

public MRESReturn DHookCallback_PreClientUpdate_Post()
{
	// Set it back afterwards
	GameRules_SetProp("m_bPlayingMannVsMachine", true);
	
	return MRES_Handled;
}

public MRESReturn DHookCallback_AllocateBots_Pre(int populator)
{
	// No bots in MY home!
	return MRES_Supercede;
}

/*
 * This detour supercedes the original function and recreates it
 * as accurately as possible to spawn players instead of bots.
 */
public MRESReturn DHookCallback_Spawn_Pre(Address pThis, DHookReturn ret, DHookParam params)
{
	CTFBotSpawner m_spawner = CTFBotSpawner(pThis);
	
	int newPlayer = -1;
	
	float rawHere[3];
	params.GetVector(1, rawHere);
	
	float here[3];
	here = Vector(rawHere[0], rawHere[1], rawHere[2]);
	
	CTFNavArea area = view_as<CTFNavArea>(TheNavMesh.GetNearestNavArea(here, .checkGround = false));
	if (area && area.HasAttributeTF(NO_SPAWNING))
	{
		ret.Value = false;
		return MRES_Supercede;
	}
	
	if (GameRules_IsMannVsMachineMode())
	{
		if (GameRules_GetRoundState() != RoundState_RoundRunning)
		{
			ret.Value = false;
			return MRES_Supercede;
		}
	}
	
	// the ground may be variable here, try a few heights
	float z;
	for (z = 0.0; z < sv_stepsize.FloatValue; z += 4.0)
	{
		here[2] = rawHere[2] + sv_stepsize.FloatValue;
		
		if (IsSpaceToSpawnHere(here))
		{
			break;
		}
	}
	
	if (z >= sv_stepsize.FloatValue)
	{
		ret.Value = false;
		return MRES_Supercede;
	}
	
	// TODO: Engineer hints
	/*if (TFGameRules() && TFGameRules()- > GameRules_IsMannVsMachineMode())
	{
		if (m_class == TF_CLASS_ENGINEER && m_defaultAttributes.m_attributeFlags & CTFBot::TELEPORT_TO_HINT && CTFBotMvMEngineerHintFinder::FindHint(true, false) == false)
		{
			if (tf_populator_debug.GetBool())
			{
				DevMsg("CTFBotSpawner: %3.2f: *** No teleporter hint for engineer\n", gpGlobals- > curtime);
			}
			
			return false;
		}
	}*/
	
	// find dead player we can re-use
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client))
			continue;
		
		if (TF2_GetClientTeam(client) != TFTeam_Spectator)
			continue;
		
		newPlayer = client;
		Player(newPlayer).ClearAllAttributes();
		break;
	}
	
	if (newPlayer != -1)
	{
		// Remove any player attributes
		TF2Attrib_RemoveAll(newPlayer);
		
		/*
		// clear any old TeleportWhere settings 
		newBot->ClearTeleportWhere();
		*/
		
		if (g_InternalSpawnPoint == INVALID_ENT_REFERENCE || EntRefToEntIndex(g_InternalSpawnPoint) == -1)
		{
			g_InternalSpawnPoint = EntIndexToEntRef(CreateEntityByName("populator_internal_spawn_point"));
			DispatchSpawn(g_InternalSpawnPoint);
		}
		
		DispatchKeyValueVector(g_InternalSpawnPoint, "origin", here);
		Player(newPlayer).m_spawnPointEntity = g_InternalSpawnPoint;
		
		TFTeam team = TFTeam_Red;
		
		if (GameRules_IsMannVsMachineMode())
		{
			team = TFTeam_Invaders;
		}
		
		// TODO: CTFBot::ChangeTeam does a little bit more, like making team switches silent
		TF2_ChangeClientTeam(newPlayer, team);
		
		char m_iszClassIcon[64];
		m_spawner.GetClassIcon(m_iszClassIcon, sizeof(m_iszClassIcon));
		
		SetEntProp(newPlayer, Prop_Data, "m_bAllowInstantSpawn", true);
		FakeClientCommand(newPlayer, "joinclass %s", g_aRawPlayerClassNames[m_spawner.m_class]);
		SetEntPropString(newPlayer, Prop_Send, "m_iszClassIcon", m_iszClassIcon);
		
		// TODO: Implement the EventChangeAttributes system
		//ClearEventChangeAttributes();
		/*CUtlVector eventChangeAttributes = CUtlVector(address + view_as<Address>(0x0A4));
		PrintToChatAll("m_eventChangeAttributes:size %d",eventChangeAttributes.Count());
		for ( int i=0; i<eventChangeAttributes.Count(); ++i )
		{
			PrintToChatAll("%i: %i", i, eventChangeAttributes.Get(i, 11));
			int skill = LoadFromAddress(eventChangeAttributes.Get(i, 11) + 0x14, NumberType_Int32);
			PrintToServer("skill %d", skill);
			//3C LInux
			//newBot->AddEventChangeAttributes( &m_eventChangeAttributes[i] );
		}*/
		
		// newBot->SetTeleportWhere( m_teleportWhereName );
		
		if (m_spawner.m_defaultAttributes.m_attributeFlags & MINIBOSS)
		{
			SetEntProp(newPlayer, Prop_Send, "m_bIsMiniBoss", true);
		}
		
		if (m_spawner.m_defaultAttributes.m_attributeFlags & USE_BOSS_HEALTH_BAR)
		{
			SetEntProp(newPlayer, Prop_Send, "m_bUseBossHealthBar", true);
		}
		
		if (m_spawner.m_defaultAttributes.m_attributeFlags & BULLET_IMMUNE)
		{
			TF2_AddCondition(newPlayer, TFCond_BulletImmune);
		}
		
		if (m_spawner.m_defaultAttributes.m_attributeFlags & BLAST_IMMUNE)
		{
			TF2_AddCondition(newPlayer, TFCond_BlastImmune);
		}
		
		if (m_spawner.m_defaultAttributes.m_attributeFlags & FIRE_IMMUNE)
		{
			TF2_AddCondition(newPlayer, TFCond_FireImmune);
		}
		
		Player(newPlayer).OnEventChangeAttributes(m_spawner.m_defaultAttributes);
		
		if (GameRules_IsMannVsMachineMode())
		{
			// initialize currency to be dropped on death to zero
			SetEntProp(newPlayer, Prop_Send, "m_nCurrency", 0);
			
			// announce Spies
			if (m_spawner.m_class == TFClass_Spy)
			{
				int spyCount = 0;
				for (int client = 1; client <= MaxClients; client++)
				{
					if (IsClientInGame(client) && IsPlayerAlive(client) && TF2_GetClientTeam(client) == TFTeam_Invaders)
					{
						if (TF2_GetPlayerClass(client) == TFClass_Spy)
						{
							++spyCount;
						}
					}
				}
				
				Event event = CreateEvent("mvm_mission_update");
				if (event)
				{
					event.SetInt("class", view_as<int>(TFClass_Spy));
					event.SetInt("count", spyCount);
					event.Fire();
				}
			}
			
		}
		
		Player(newPlayer).SetScaleOverride(m_spawner.m_scale);
		
		int nHealth = m_spawner.m_health;
		
		if (nHealth <= 0.0)
		{
			nHealth = TF2Util_GetEntityMaxHealth(newPlayer);
		}
		
		// TODO: Support populator health multiplier
		// nHealth *= g_pPopulationManager->GetHealthMultiplier( false );
		Player(newPlayer).ModifyMaxHealth(nHealth);
		
		Player(newPlayer).StartIdleSound();
		
		if (Player(newPlayer).HasAttribute(SPAWN_WITH_FULL_CHARGE))
		{
			int weapon = GetPlayerWeaponSlot(newPlayer, TF_WPN_TYPE_SECONDARY);
			if (weapon != -1 && HasEntProp(weapon, Prop_Send, "m_flChargeLevel"))
			{
				SetEntPropFloat(weapon, Prop_Send, "m_flChargeLevel", 1.0);
			}
			
			SetEntPropFloat(newPlayer, Prop_Send, "m_flRageMeter", 100.0);
		}
		
		TFClassType nClassIndex = TF2_GetPlayerClass(newPlayer);
		
		bool halloweenPopFile = false;
		if (halloweenPopFile)
		{
			// TODO: Implement Halloween popfile
		}
		else
		{
			if (nClassIndex >= TFClass_Scout && nClassIndex <= TFClass_Engineer)
			{
				if (m_spawner.m_scale >= FindConVar("tf_mvm_miniboss_scale").FloatValue || GetEntProp(newPlayer, Prop_Send, "m_bIsMiniBoss") && FileExists(g_szBotBossModels[nClassIndex], true))
				{
					SetVariantString(g_szBotBossModels[nClassIndex]);
					AcceptEntityInput(newPlayer, "SetCustomModel");
					SetEntProp(newPlayer, Prop_Send, "m_bUseClassAnimations", true);
					SetEntProp(newPlayer, Prop_Data, "m_bloodColor", DONT_BLEED);
				}
				else if (FileExists(g_szBotModels[nClassIndex], true))
				{
					SetVariantString(g_szBotModels[nClassIndex]);
					AcceptEntityInput(newPlayer, "SetCustomModel");
					SetEntProp(newPlayer, Prop_Send, "m_bUseClassAnimations", true);
					SetEntProp(newPlayer, Prop_Data, "m_bloodColor", DONT_BLEED);
				}
			}
		}
		
		if (params.Get(2))
		{
			// EntityHandleVector_t
			CUtlVector result = CUtlVector(params.Get(2));
			result.AddToTail(LoadFromAddress(SDKCall_GetRefEHandle(newPlayer), NumberType_Int32));
		}
		
		// For easy access in WaveSpawnPopulator::Update()
		m_justSpawnedVector.Push(newPlayer);
	}
	else
	{
		ret.Value = false;
		return MRES_Supercede;
	}
	
	ret.Value = true;
	return MRES_Supercede;
}

public MRESReturn DHookCallback_WaveSpawnPopulatorUpdate_Post(Address pThis)
{
	for (int i = 0; i < m_justSpawnedVector.Length; i++)
	{
		int player = m_justSpawnedVector.Get(i);
		
		SetEntProp(player, Prop_Send, "m_nCurrency", 0);
		SetEntData(player, g_OffsetWaveSpawnPopulator, pThis);
		
		char iszClassIconName[64];
		GetEntPropString(player, Prop_Send, "m_iszClassIcon", iszClassIconName, sizeof(iszClassIconName));
		
		// Allows client UI to know if a specific spawner is active
		SetMannVsMachineWaveClassActive(iszClassIconName);
		
		bool bLimitedSupport = LoadFromAddress(pThis + view_as<Address>(g_OffsetLimitedSupport), NumberType_Int8);
		if (bLimitedSupport)
		{
			SetEntData(player, g_OffsetIsLimitedSupportEnemy, true);
		}
		
		// TODO
		/*
		// what bot should do after spawning at teleporter exit
		if ( bTeleported )
		{
			OnBotTeleported( bot );
		}
		*/
	}
	
	// After we are done, clear the vector
	m_justSpawnedVector.Clear();
	
	return MRES_Supercede;
}

public MRESReturn DHookCallback_MissionPopulatorUpdateMission_Post(Address pThis, DHookReturn ret, DHookParam params)
{
	for (int i = 0; i < m_justSpawnedVector.Length; i++)
	{
		int player = m_justSpawnedVector.Get(i);
		
		SetEntData(player, g_OffsetIsMissionEnemy, true);
		
		char iszClassIconName[64];
		GetEntPropString(player, Prop_Send, "m_iszClassIcon", iszClassIconName, sizeof(iszClassIconName));
		
		int iFlags = MVM_CLASS_FLAG_MISSION;
		if (GetEntProp(player, Prop_Send, "m_bIsMiniBoss"))
		{
			iFlags |= MVM_CLASS_FLAG_MINIBOSS;
		}
		else if (Player(player).HasAttribute(ALWAYS_CRIT))
		{
			iFlags |= MVM_CLASS_FLAG_ALWAYSCRIT;
		}
		IncrementMannVsMachineWaveClassCount(iszClassIconName, iFlags);
	}
	
	// After we are done, clear the vector
	m_justSpawnedVector.Clear();
	
	return MRES_Handled;
}

public MRESReturn DHookCallback_GetTeamAssignmentOverride_Pre(DHookReturn ret, DHookParam params)
{
	GameRules_SetProp("m_bPlayingMannVsMachine", false);
	
	return MRES_Ignored;
}

public MRESReturn DHookCallback_GetTeamAssignmentOverride_Post(DHookReturn ret, DHookParam params)
{
	GameRules_SetProp("m_bPlayingMannVsMachine", true);
	
	return MRES_Ignored;
}

public MRESReturn DHookCallback_GetLoadoutItem_Pre(int player, DHookReturn ret, DHookParam params)
{
	// Generate base items for robot players
	if (TF2_GetClientTeam(player) == TFTeam_Invaders)
	{
		GameRules_SetProp("m_bIsInTraining", true);
	}
	
	return MRES_Ignored;
}

public MRESReturn DHookCallback_GetLoadoutItem_Post(int player, DHookReturn ret, DHookParam params)
{
	if (TF2_GetClientTeam(player) == TFTeam_Invaders)
	{
		GameRules_SetProp("m_bIsInTraining", false);
	}
	
	return MRES_Ignored;
}

public MRESReturn DHookCallback_EventKilled_Pre(int client, DHookParam params)
{
	// TODO: Only do this for BLU team
	SetEntityFlags(client, GetEntityFlags(client) | FL_FAKECLIENT);
	
	return MRES_Ignored;
}

public MRESReturn DHookCallback_EventKilled_Post(int client, DHookParam params)
{
	SetEntityFlags(client, GetEntityFlags(client) & ~FL_FAKECLIENT);
	
	return MRES_Ignored;
}

public MRESReturn DHookCallback_PassesFilterImpl_Pre(int filter, DHookReturn ret, DHookParam params)
{
	int pEntity = params.Get(2);
	if (0 < pEntity < MaxClients && TF2_GetClientTeam(pEntity) == TFTeam_Invaders)
	{
		bool m_bRequireAllTags = GetEntProp(filter, Prop_Data, "m_bRequireAllTags") != 0;
		
		char m_iszTags[256];
		GetEntPropString(filter, Prop_Data, "m_iszTags", m_iszTags, sizeof(m_iszTags));
		
		// max. 4 tags with a length of 64 chars
		char tags[4][64];
		int count = ExplodeString(m_iszTags, " ", tags, sizeof(tags), sizeof(tags[]));
		
		bool bPasses = false;
		for (int i = 0; i < count; ++i)
		{
			if (Player(pEntity).HasTag(tags[i]))
			{
				bPasses = true;
				if (!m_bRequireAllTags)
				{
					break;
				}
			}
			else if (m_bRequireAllTags)
			{
				ret.Value = false;
				return MRES_Supercede;
			}
		}
		
		ret.Value = bPasses;
		return MRES_Supercede;
	}
	
	return MRES_Ignored;
}
