#include <chat-processor>
#include <clientprefs>
#include <convars>
#include <dbi>
#include <events>
#include <menus>
#include <sdkhooks>
#include <sourcemod>
#include <tf2_stocks>

public Plugin:myinfo =
{
	name = "SNT Ranking Plugin",
	author = "Arcala the Gyiyg",
	description = "A player ranking system that tracks kills and assists.",
	version = "1.0.0",
	url = "N/A"
}

// Thanks to Tec Dias, the creator of Easy Rank SQL which I based some of my code on.

bool g_bIsEnabled;
int g_iPlayerRank[MAXPLAYERS + 1];
int g_iPlayerKillstreak[MAXPLAYERS + 1];
int g_iTotalPlayers;
float g_fTop10Scores[10];
float g_fPlayerScore[MAXPLAYERS + 1];
float g_fKillstreakMod[MAXPLAYERS + 1];
Database db;
Menu g_mRankMenu;
ConVar g_cvPointsKill;
ConVar g_cvPointsAssist;
ConVar g_cvPointsAssistMedic;
ConVar g_cvDisplayKillstreakMessages;
Cookie g_ckDisplayRank;

public void SQL_ErrorLogger(Handle owner, Handle hndl, const String:error[], any data)
{
    if (!StrEqual("", error))
    {
        PrintToServer("[SNTRank] Could not complete query: %s", error)
    }
}

public void SQL_OnClientConnect(Handle owner, Handle hndl, const String:error[], any data)
{
    int client = GetClientOfUserId(data);
    if (client == 0)
    {
        return;
    }
    if (hndl == INVALID_HANDLE)
    {
        LogError("[SNTRanks]: Query failed: %s", error);
    }
    else
    {
        char query[512];
        char _cClientNameBuffer[MAXLENGTH_NAME];
        char _cEscapedClientName[(MAX_NAME_LENGTH*2)+1];
        char _cClientId[32];
        GetClientAuthId(client, AuthId_Steam3, _cClientId, sizeof(_cClientId));
        GetClientName(client, _cClientNameBuffer, sizeof(_cClientNameBuffer));
        SQL_EscapeString(db, _cClientNameBuffer, _cEscapedClientName, sizeof(_cEscapedClientName));
        if (!SQL_MoreRows(hndl))
        {
            Format(query, sizeof(query), "INSERT INTO snt_playerrank (steamid, name, score) VALUES ('%s', '%s', 0.0)", _cClientId, _cEscapedClientName);
            //add the player to the database, they dont exist right now
            // if (query[0]) {
            //     PrintToServer("[SNTRank-LOG] Query: %s", query );
            // } else {
            //     PrintToServer("[SNTRank-LOG] Query: %s", "NULL" );
            // }
            SQL_TQuery(db, SQL_ErrorLogger, query);
            g_fPlayerScore[client] = 0.0;
            PrintToServer("[SNTRank] Success! Client ID: %s, Client Name: %s added to the database!", _cClientId, _cClientNameBuffer);
        }
        else
        {
            
            Format(query, sizeof(query), "UPDATE snt_playerrank SET name='%s' WHERE steamid='%s'", _cEscapedClientName, _cClientId);
            // if (query[0]) {
            //     PrintToServer("[SNTRank-LOG] Query: %s", query );
            // } else {
            //     PrintToServer("[SNTRank-LOG] Query: %s", "NULL" );
            // }
            SQL_TQuery(db, SQL_ErrorLogger, query);
            PrintToServer("[SNTRank] Success! Updated Client ID: %s's name to %s in the database!", _cClientId, _cClientNameBuffer); 
            while (SQL_FetchRow(hndl))
            {
                g_fPlayerScore[client] = SQL_FetchFloat(hndl, 0);
            }
        }
    }

    CloseHandle(hndl);
}

void SQL_SyncDatabase()
{
    char _cAuthId[32];
    char query[512];
    int _iClientCount = GetClientCount(true);
    int _iClientUserId;
    int i;
    // PrintToServer("%i", _iClientCount);
    for (i = 0; i <= _iClientCount; i++)
    {
        if (i == 0)
        {
            // PrintToServer("Server Index");
        }
        else
        {
            if (IsClientConnected(i))
            {
                if (IsClientInGame(i) && !IsFakeClient(i))
                {
                    _iClientUserId = GetClientUserId(i);
                    GetClientAuthId(i, AuthId_Steam3, _cAuthId, sizeof(_cAuthId));
                    // PrintToServer("Client Auth Id %s", _cAuthId);
                    Format(query, sizeof(query), "SELECT score FROM snt_playerrank WHERE steamid='%s'", _cAuthId);
                    // PrintToServer("Query %s", query);
                    SQL_TQuery(db, SQL_OnClientConnect, query, _iClientUserId);
                    Format(query, sizeof(query), "SELECT * FROM snt_playerrank ORDER BY score DESC", _cAuthId);
                    SQL_TQuery(db, SQL_RetreivePlayerRank, query, _iClientUserId);
                }
            }
            else
            {
                LogError("[SNTRanks]: Client %i not connected", i);
            }
        }
    }
}

public void SQL_RetreivePlayerRank(Handle owner, Handle hndl, const String:error[], any data)
{
    int client = GetClientOfUserId(data);
    char _cClientAuth[32];
    char _cFetchedAuth[32];
    GetClientAuthId(client, AuthId_Steam3, _cClientAuth, sizeof(_cClientAuth));

    int i;
    if (client == 0)
    {
        return;
    }
    if (!StrEqual(error, ""))
    {
        LogError("[SNTRank]: Query failed because: %s", error);
    }
    g_iTotalPlayers = SQL_GetRowCount(hndl);
    while (SQL_FetchRow(hndl))
    {
        i++;
        SQL_FetchString(hndl, 0, _cFetchedAuth, sizeof(_cFetchedAuth));
        if (StrEqual(_cFetchedAuth, _cClientAuth))
        {
            g_iPlayerRank[client] = i;
        }
    }
}

public Action Timer_Message(Handle timer, any data)
{
    PrintToChatAll("\x04[SNTRank]: \x01Use /rank or /ranks to open the rank menu!");
    return Plugin_Continue;
}

public void OnPluginStart()
{
    char error[255];
    db = SQL_Connect("sntdb", true, error, sizeof(error));

    if (db == null)
    {
        PrintToServer("[SNTRank] Could not connect to database: %s", error);
    }

    g_ckDisplayRank = RegClientCookie("sm_displayrank", "Whether your rank is displayed or not", CookieAccess_Private);

    SQL_TQuery(db, SQL_ErrorLogger, "CREATE TABLE IF NOT EXISTS snt_playerrank (steamid varchar(32) NOT NULL PRIMARY KEY, name varchar(64) NOT NULL, score float NOT NULL DEFAULT 0.0)");

    g_cvPointsKill = CreateConVar("sm_pointsonkill", "4.0", "The amount of points players get per kill, min: 2", 0, true, 2.0, false);
    g_cvPointsAssist = CreateConVar("sm_pointsonassist", "2.0", "The amount of points players get when they assist with a kill, min: 1", 0, true, 1.0, false);
    g_cvPointsAssistMedic = CreateConVar("sm_pointsonassist_medic", "4.0", "How many points a medic gets if they assist with a kill min: 1", 0, true, 1.0, false);
    g_cvDisplayKillstreakMessages = CreateConVar("sm_killstreakdisplay", "2.0", "Displays killstreak messages to chat. 0 = No Messages, 1 = Send to Killstreaker Only, 2 = Display to all", 0, true, 0.0, true, 2.0);

    RegAdminCmd("sm_resetallranks", Action_ResetRanks, ADMFLAG_ROOT);
    RegAdminCmd("sm_rmvfrmrank", Action_RemoveRankID, ADMFLAG_BAN);
    RegAdminCmd("sm_resetrank", Action_ResetRankID, ADMFLAG_BAN);
    RegAdminCmd("sm_syncranks", Action_SyncDatabase, ADMFLAG_SLAY);

    RegConsoleCmd("sm_rank", Action_ShowRankMenu);
    RegConsoleCmd("sm_ranks", Action_ShowRankMenu);

    HookEvent("player_death", Event_PlayerDeath);

    SQL_SyncDatabase();

    CreateTimer(300.0, Timer_Message, 0, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

}

public OnAllPluginsLoaded()                     //  Check for necessary plugin dependencies and shut down this plugin if not found.
{
    if (!LibraryExists("chat-processor"))
    {
        SetFailState("[SNTRanks] Chat Processor is not loaded, please load chat-processor.smx");
    }
}

public OnLibraryAdded(const String:name[])      //  Enable the plugin if the necessary library is added
{
    if (StrEqual(name, "chat-processor"))
    {
        g_bIsEnabled = true;
    }
}

public OnLibraryRemoved(const String:name[])    //  If a necessary plugin is removed, also shut this one down.
{
    if (StrEqual(name, "chat-processor"))
    {
        g_bIsEnabled = false;
    }
}

bool ReturnClientPref(int client)
{
    if (AreClientCookiesCached(client))
    {
        char _cCookieBuffer[32];
        GetClientCookie(client, g_ckDisplayRank, _cCookieBuffer, sizeof(_cCookieBuffer));
        if (StrEqual(_cCookieBuffer, "enabled"))
        {
            return true;
        }
        return false;
    }
    return false;
}

void PrintPlayerKillstreak(int client)
{
    char _cClientName[64];
    GetClientName(client, _cClientName, sizeof(_cClientName))
    switch(g_cvDisplayKillstreakMessages.FloatValue)
    {
        case 0.0:
            return;
        case 1.0:
            switch(g_iPlayerKillstreak[client])
            {
                case 5:
                {
                    PrintToChat(client, "\x04[SNTRanks]: \x01You're on a killing spree! You get an additional \x05(1.5x) \x01Points!")
                }
                case 10:
                {
                    PrintToChat(client, "\x04[SNTRanks]: \x01You're unstoppable! You get an additional \x05(1.5x) \x01Points!")
                }
                case 15:
                {
                    PrintToChat(client, "\x04[SNTRanks]: \x01You're on a rampage! You get an additional \x05(2x) \x01Points!")
                }
                case 20:
                {
                    PrintToChat(client, "\x04[SNTRanks]: \x01You're god-like! You get an additional \x05(2x) \x01Points!")
                }
            }
        case 2.0:
            switch(g_iPlayerKillstreak[client])
            {
                case 5:
                {
                    PrintToChatAll("\x04[SNTRanks]: \x01%s is on a killing spree! They get an additional \x05(1.5x) \x01Points!", _cClientName)
                }
                case 10:
                {
                    PrintToChatAll("\x04[SNTRanks]: \x01%s is unstoppable! They get an additional \x05(1.5x) \x01Points!", _cClientName)
                }
                case 15:
                {
                    PrintToChatAll("\x04[SNTRanks]: \x01%s is on a rampage! They get an additional \x05(2x) \x01Points!", _cClientName)
                }
                case 20:
                {
                    PrintToChatAll("\x04[SNTRanks]: \x01%s is god-like! They get an additional \x05(2x) \x01Points!", _cClientName)
                }
            } 
    }
}

public void SQL_GetTop10Scores(Handle owner, Handle hndl, const String:error[], any data)
{
    int i;
    if (hndl == INVALID_HANDLE || !StrEqual(error, ""))
    {
        LogError("[SNTRanks]: Query failed: %s", error);
        return;
    }
    while (SQL_FetchRow(hndl))
    {
        g_fTop10Scores[i] = SQL_FetchFloat(hndl, 0);
        i++;
    }
}

public void SQL_GetTop10Players(Handle owner, Handle hndl, const String:error[], any data)
{
    int client = GetClientOfUserId(data);
    char _cPlayerBuffer[64];
    char _cTop10Buffer[128];
    int i;
    int y;
    if (client == 0)
    {
        return;
    }
    if (hndl == INVALID_HANDLE || !StrEqual(error, ""))
    {
        LogError("[SNTRanks]: Query failed: %s", error);
        return;
    }
    while (SQL_FetchRow(hndl))
    {   
        i++;
        SQL_FetchString(hndl, 0, _cPlayerBuffer, sizeof(_cPlayerBuffer));
        switch(i)
        {
            case 1: Format(_cTop10Buffer, sizeof(_cTop10Buffer), "\x05%ist \x01| \x05%s \x01| \x05%0.1f \x01points.", i, _cPlayerBuffer, g_fTop10Scores[y]);
            case 2: Format(_cTop10Buffer, sizeof(_cTop10Buffer), "\x05%ind \x01| \x05%s \x01| \x05%0.1f \x01points.", i, _cPlayerBuffer, g_fTop10Scores[y]);
            case 3: Format(_cTop10Buffer, sizeof(_cTop10Buffer), "\x05%ird \x01| \x05%s \x01| \x05%0.1f \x01points.", i, _cPlayerBuffer, g_fTop10Scores[y]);
            default: Format(_cTop10Buffer, sizeof(_cTop10Buffer), "\x05%ith \x01| \x05%s \x01| \x05%0.1f \x01points.", i, _cPlayerBuffer, g_fTop10Scores[y]);
        }
        PrintToChat(client, "\x04[SNTRank]: %s", _cTop10Buffer);
        y++;
    }
}

void setup_Top10Plyrs(int client)
{
    char query[512];
    int _iUserId = GetClientUserId(client);
    Format(query, sizeof(query), "SELECT score FROM snt_playerrank ORDER BY score DESC LIMIT 0,10");
    SQL_TQuery(db, SQL_GetTop10Scores, query);
    Format(query, sizeof(query), "SELECT name FROM snt_playerrank ORDER BY score DESC LIMIT 0,10 ");
    SQL_TQuery(db, SQL_GetTop10Players, query, _iUserId);
}

public int Info_Menu_Handler(Menu menu, MenuAction action, int param1, int param2)
{
    switch(action)
    {
        case MenuAction_Select:
        {
            char menuItemBuffer[32];
            menu.GetItem(param2, menuItemBuffer, sizeof(menuItemBuffer));
            if (StrEqual(menuItemBuffer, "OPT_VIEWRANK"))
            {
                int _cClientIndex = GetClientUserId(param1);
                char query[512];
                char _cAuthId[32];
                GetClientAuthId(param1, AuthId_Steam3, _cAuthId, sizeof(_cAuthId));
                Format(query, sizeof(query), "SELECT * FROM snt_playerrank ORDER BY score DESC", _cAuthId);
                SQL_TQuery(db, SQL_RetreivePlayerRank, query, _cClientIndex);
                PrintToChat(param1, "\x04[SNTRank]: \x01You are rank: \x05%i \x01out of: \x05%i", g_iPlayerRank[param1], g_iTotalPlayers);
                PrintToChat(param1, "\x04[SNTRank]: \x01You have \x05%0.1f \x01points.", g_fPlayerScore[param1]);
            }
            else if (StrEqual(menuItemBuffer, "OPT_TOGGLEDISPLAY"))
            {
                if (ReturnClientPref(param1))
                {
                    SetClientCookie(param1, g_ckDisplayRank, "disabled");
                    PrintToChat(param1, "\x04[SNTRank]: \x01Sucessfully stopped displaying your rank in chat.");
                }
                else if (!ReturnClientPref(param1))
                {
                    SetClientCookie(param1, g_ckDisplayRank, "enabled");
                    PrintToChat(param1, "\x04[SNTRank]: \x01Sucessfully started displaying your rank in chat.");
                }
            }
            else if (StrEqual(menuItemBuffer, "OPT_TOP10"))
            {
                setup_Top10Plyrs(param1);
            }
            else if (StrEqual(menuItemBuffer, "OPT_RESETRANK"))
            {
                PrintToChat(param1, "\x04[SNTRank]: \x01If you're really sure about resetting your rank, type /rank reset CONFIRM.");
                PrintToChat(param1, "\x04[SNTRank]: \x01If you reset your rank, admins will not be able to retreive it.");
            }
        }
        case MenuAction_Cancel:
        {
            return 0;
        }
        case MenuAction_End:
        {
            delete menu;
        }
    }
    return 0;
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (g_bIsEnabled)
    {
        int client = GetClientOfUserId(GetEventInt(event, "userid"));
        int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
        int assister  = GetClientOfUserId(GetEventInt(event, "assister"));
        char _cClientName[MAXLENGTH_NAME];
        char _cAttackerName[MAXLENGTH_NAME];
        char _cAttackerAuthId[32];
        char query[512];

        GetClientName(client, _cClientName, sizeof(_cClientName));
        GetClientName(attacker, _cAttackerName, sizeof(_cAttackerName));
        GetClientAuthId(attacker, AuthId_Steam3, _cAttackerAuthId, sizeof(_cAttackerAuthId));

        if (!IsFakeClient(client) && client == attacker && client != 0)
        {
            if (g_iPlayerKillstreak[client] >= 5)
            {
                
                switch (g_cvDisplayKillstreakMessages.FloatValue)
                {
                    case 0.0:
                        return Plugin_Continue;
                    case 1.0:
                        PrintToChat(client, "\x04[SNTRanks]: \x01You ended your own killstreak.");
                    case 2.0:
                        PrintToChatAll("\x04[SNTRanks]: \x01%s ended their own killstreak!", _cClientName);
                }
            }
            g_iPlayerKillstreak[client] = 0;
        }
        if (!IsFakeClient(client) && !IsFakeClient(attacker) && client != attacker && client != 0 && attacker != 0)
        {
            switch(g_iPlayerKillstreak[attacker])
            {
                case 0:
                    g_fKillstreakMod[attacker] = 1.0;
                case 5:
                    g_fKillstreakMod[attacker] = 1.5;
                case 15:
                    g_fKillstreakMod[attacker] = 2.0;
            }
            g_iPlayerKillstreak[attacker]++;
            g_fPlayerScore[attacker] += (g_cvPointsKill.FloatValue * g_fKillstreakMod[attacker]);
            Format(query, sizeof(query), "UPDATE snt_playerrank SET score=%f WHERE steamid='%s'", g_fPlayerScore[attacker], _cAttackerAuthId);
            SQL_TQuery(db, SQL_ErrorLogger, query);
            if (g_iPlayerKillstreak[client] >= 5)
            {
                switch (g_cvDisplayKillstreakMessages.FloatValue)
                {
                    case 0.0:
                        return Plugin_Continue;
                    case 1.0:
                        PrintToChat(client, "\x04[SNTRanks]: \x01You've been killed by %s, your killstreak has been ended!", _cAttackerName);
                    case 2.0:
                        PrintToChatAll("\x04[SNTRanks]: \x01%s has killed %s and ended their killstreak!", _cAttackerName, _cClientName);
                }
            }
            if (event.GetInt("death_flags") & TF_DEATHFLAG_DEADRINGER)
            {
                return Plugin_Continue;
            }
            else
            {
                g_iPlayerKillstreak[client] = 0;
            }
            if (assister != 0 && !IsFakeClient(assister))
            {
                char _cAssisterAuthId[32];
                GetClientAuthId(assister, AuthId_Steam3, _cAssisterAuthId, sizeof(_cAssisterAuthId));
                if (TF2_GetPlayerClass(assister) != TFClass_Medic)
                {
                    g_fPlayerScore[assister] += g_cvPointsAssist.FloatValue;
                    Format(query, sizeof(query), "UPDATE snt_playerrank SET score=%f WHERE steamid='%s'", g_fPlayerScore[assister], _cAssisterAuthId);
                    SQL_TQuery(db, SQL_ErrorLogger, query);
                }
                else
                {
                    g_iPlayerKillstreak[assister]++;
                    PrintPlayerKillstreak(assister);
                    switch(g_iPlayerKillstreak[assister])
                    {
                        case 0:
                            g_fKillstreakMod[assister] = 1.0;
                        case 5:
                            g_fKillstreakMod[assister] = 1.5;
                        case 15:
                            g_fKillstreakMod[assister] = 2.0;
                    }
                    if (g_iPlayerKillstreak[assister] > 5)
                    {
                        g_fPlayerScore[assister] += (g_cvPointsAssistMedic.FloatValue * g_fKillstreakMod[assister]);
                    }
                    Format(query, sizeof(query), "UPDATE snt_playerrank SET score=%f WHERE steamid='%s'", g_fPlayerScore[assister], _cAssisterAuthId);
                    SQL_TQuery(db, SQL_ErrorLogger, query);
                }
            }
            PrintPlayerKillstreak(attacker);
        }
    }
    SQL_SyncDatabase();
    return Plugin_Continue;
}

public Action CP_OnChatMessage(int& author, ArrayList recipients, char[] flagstring, char[] name, char[] message, bool & processcolors, bool & removecolors)
{
    char query[512];
    int _cAuthorIndex = GetClientUserId(author);
    if (g_bIsEnabled && ReturnClientPref(author))
    {
        Format(query, sizeof(query), "SELECT * FROM snt_playerrank ORDER BY score DESC");
        SQL_TQuery(db, SQL_RetreivePlayerRank, query, _cAuthorIndex);
        Format(name, MAXLENGTH_NAME, "#%i | \x03%s", g_iPlayerRank[author], name);
    }
    return Plugin_Changed;
}

public Action:Action_ShowRankMenu(int client, int args)
{
    char _cArgs1[64];
    char _cArgs2[64];
    char query[512];
    char _cAuthId[32];
    AdminId _aidAdmin = GetUserAdmin(client);
    GetClientAuthId(client, AuthId_Steam3, _cAuthId, sizeof(_cAuthId));
    if (args == 0)
    {
        g_mRankMenu = new Menu(Info_Menu_Handler, MENU_ACTIONS_DEFAULT);
        g_mRankMenu.SetTitle("SNTRank Menu");
        g_mRankMenu.AddItem("OPT_VIEWRANK", "View your current rank info!");
        g_mRankMenu.AddItem("OPT_RESETRANK", "Reset your current rank!");
        g_mRankMenu.AddItem("OPT_TOGGLEDISPLAY", "Toggle your rank display!");
        g_mRankMenu.AddItem("OPT_TOP10", "View the top 10 players!");
        g_mRankMenu.Display(client, MENU_TIME_FOREVER);
        return Plugin_Handled;
    }
    else if (args == 1)
    {
        GetCmdArg(1, _cArgs1, sizeof(_cArgs1));
        if (StrEqual(_cArgs1, "admin") && _aidAdmin.HasFlag(Admin_Slay))
        {
            ReplyToCommand(client, "\x04[SNTRank]: \x01Owners can use '/resetallranks CONFIRM' to reset the rank database.");
            ReplyToCommand(client, "\x04[SNTRank]: \x01Admins can use '/rmvfrmrank Steam3ID' to remove a Steam3ID from the rank table");
            ReplyToCommand(client, "\x04[SNTRank]: \x01Admins may also use '/resetrank Steam3ID' to reset a user's rank to 0")
            ReplyToCommand(client, "\x04[SNTRank]: \x01Any admin level can use /syncranks to resync the rank database if needed.");
            return Plugin_Handled;
        }
        else
        {
            ReplyToCommand(client, "\x04[SNTRank]: \x01Usage /rank, /ranks");
            return Plugin_Handled;
        }
    }
    else if (args == 2)
    {
        GetCmdArg(1, _cArgs1, sizeof(_cArgs1));
        GetCmdArg(2, _cArgs2, sizeof(_cArgs2));
        if (StrEqual(_cArgs1, "reset") && StrEqual(_cArgs2, "CONFIRM"))
        {   
            Format(query, sizeof(query), "UPDATE snt_playerrank SET score=0.0 WHERE steamid='%s'", _cAuthId);
            SQL_TQuery(db, SQL_ErrorLogger, query);
            SQL_SyncDatabase();
            ReplyToCommand(client, "\x04[SNTRank]: \x01Successfully reset your rank.")
            return Plugin_Handled;
        }
        else
        {
            ReplyToCommand(client, "\x04[SNTRank]: \x01Usage /rank, /ranks");
            return Plugin_Handled;
        }
    }
    else
    {
        ReplyToCommand(client, "\x04[SNTRank]: \x01Usage /rank, /ranks");
        return Plugin_Handled;
    }    
}

public Action:Action_ResetRanks(int client, int args)
{
    if (args < 1 || args > 1)
    {
        ReplyToCommand(client, "\x04[SNTRank] Usage: \x01/resetallranks CONFIRM");
        return Plugin_Handled;
    }
    char _cArgs[32];
    char query[512];
    GetCmdArg(1, _cArgs, sizeof(_cArgs));
    if (StrEqual(_cArgs, "CONFIRM"))
    {
        Format(query, sizeof(query), "UPDATE snt_playerrank SET score=0.0");
        SQL_TQuery(db, SQL_ErrorLogger, query);
        SQL_SyncDatabase();
        ReplyToCommand(client, "\x04[SNTRank]: \x01Successfully reset all scores in the database.");
    }
    else
    {
        ReplyToCommand(client, "\x04[SNTRank] Usage: \x01/resetallranks CONFIRM");
    }
    return Plugin_Handled;
}

public Action:Action_SyncDatabase(int client, int args)
{
    if (args != 0)
    {
        ReplyToCommand(client, "\x04[SNTRank] Usage: \x01/syncranks");
        return Plugin_Handled;
    }
    SQL_SyncDatabase();
    ReplyToCommand(client, "\x04[SNTRank]: \x01Sucessfully synced database");
    return Plugin_Handled;
}

public Action:Action_RemoveRankID(int client, int args)
{
    if (args != 1)
    {
        ReplyToCommand(client, "\x04[SNTRank] Usage: \x01/rmvfrmrank \"[Steam3ID]\" (with quotes)");
    }
    else
    {
        char _cArgsBuffer[32];
        char _cArgsEsc[32];
        char query[512];
        GetCmdArgString(_cArgsBuffer, sizeof(_cArgsBuffer));
        StripQuotes(_cArgsBuffer);
        SQL_EscapeString(db, _cArgsBuffer, _cArgsEsc, sizeof(_cArgsEsc));

        Format(query, sizeof(query), "DELETE FROM snt_playerrank WHERE steamid='%s'", _cArgsEsc);
        SQL_TQuery(db, SQL_ErrorLogger, query);

        SQL_SyncDatabase();

        ReplyToCommand(client, "\x04[SNTRank]: \x01Removed Steam3ID \x05%s \x01from the database.", _cArgsBuffer);
    }
}

public Action:Action_ResetRankID(int client, int args)
{
    if (args != 1)
    {
        ReplyToCommand(client, "\x04[SNTRank] Usage: \x01/resetrank \"[Steam3ID]\" (with quotes)");
    }
    else
    {
        char _cArgsBuffer[32];
        char _cArgsEsc[32];
        char query[512];
        GetCmdArgString(_cArgsBuffer, sizeof(_cArgsBuffer));
        StripQuotes(_cArgsBuffer);
        SQL_EscapeString(db, _cArgsBuffer, _cArgsEsc, sizeof(_cArgsEsc));

        Format(query, sizeof(query), "UPDATE snt_playerrank SET score=0.0 WHERE steamid='%s'", _cArgsEsc);
        SQL_TQuery(db, SQL_ErrorLogger, query);

        SQL_SyncDatabase();

        ReplyToCommand(client, "\x04[SNTRank]: \x01Reset Steam3ID \x05%s\x01's score in the database.", _cArgsBuffer);
    }
}

public void OnClientPutInServer(int client)
{
    if (IsClientInGame(client) && g_bIsEnabled)
    {
        if (!IsFakeClient(client))
        {
            char _cAuthId[32];
            char query[512];
            int _iClientId = GetClientUserId(client);
            GetClientAuthId(client, AuthId_Steam3, _cAuthId, sizeof(_cAuthId));
            Format(query, sizeof(query), "SELECT score FROM snt_playerrank WHERE steamid='%s'", _cAuthId);
            SQL_TQuery(db, SQL_OnClientConnect, query, _iClientId);
            SQL_SyncDatabase();
        }
    }
}

public void OnClientDisconnect(int client)
{
    g_fPlayerScore[client] = 0.0;
    g_iPlayerRank[client] = 0;
    g_iPlayerKillstreak[client] = 0;
    g_fKillstreakMod[client] = 0.0;
}