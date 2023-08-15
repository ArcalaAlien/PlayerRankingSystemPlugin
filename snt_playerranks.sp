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
float g_fPlayerScore[MAXPLAYERS + 1];
Database db;
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
            Format(query, sizeof(query), "INSERT INTO snt_playerranks (steamid, name, score) VALUES ('%s', '%s', 0.0)", _cClientId, _cEscapedClientName);
            SQL_TQuery(db, SQL_ErrorLogger, query);
            g_fPlayerScore[client] = 0.0;
            PrintToServer("[SNTRank] Success! Client ID: %s, Client Name: %s added to the database!", _cClientId, _cClientNameBuffer);
        }
        else
        {
            Format(query, sizeof(query), "UPDATE snt_playerranks SET name='%s' WHERE steamid='%s'", _cEscapedClientName, _cClientId);
            SQL_TQuery(db, SQL_ErrorLogger, query);
            PrintToServer("[SNTRank] Success! Updated Client ID: %s's name to %s in the database!", _cClientId, _cClientNameBuffer); 
            while (SQL_FetchRow(hndl))
            {
                g_fPlayerScore[client] = SQL_FetchFloat(hndl, 0);
            }
        }
    }
}

void SQL_SyncDatabase()
{
    char _cAuthId[32];
    char query[512];
    int _iClientIndex;
    for (int i = 0; i <= MaxClients; i++)
    {
        _iClientIndex = GetClientUserId(i);
        if (IsClientInGame(_iClientIndex) && !IsFakeClient(_iClientIndex))
        {
            GetClientAuthId(_iClientIndex, AuthId_Steam3, _cAuthId, sizeof(_cAuthId));
            Format(query, sizeof(query), "SELECT score FROM snt_playerranks WHERE steamid=%s", _cAuthId);
            SQL_TQuery(db, SQL_OnClientConnect, query);
        }
    }
}

public void SQL_RetreivePlayerRank(Handle owner, Handle hndl, const String:error[], any data)
{
    int client = GetClientOfUserId(data);
    if (client == 0)
    {
        return;
    }
    while (SQL_FetchRow(hndl))
    {
        g_iPlayerRank[client] = SQL_FetchInt(hndl, 0);
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

    SQL_TQuery(db, SQL_ErrorLogger, "CREATE TABLE IF NOT EXISTS snt_playerrank (steamid varchar(32) NOT NULL PRIMARY KEY, name varchar(64) NOT NULL, score INT NOT NULL DEFAULT 0)");

    g_cvPointsKill = CreateConVar("sm_pointsonkill", "4.0", "The amount of points players get per kill, min: 2", 0, true, 2.0, false);
    g_cvPointsAssist = CreateConVar("sm_pointsonassist", "2.0", "The amount of points players get when they assist with a kill, min: 1", 0, true, 1.0, false);
    g_cvPointsAssistMedic = CreateConVar("sm_pointsonassist_medic", "4.0", "How many points a medic gets if they assist with a kill min: 1", 0, true, 1.0, false);
    g_cvDisplayKillstreakMessages = CreateConVar("sm_killstreakdisplay", "2.0", "Displays killstreak messages to chat. 0 = No Messages, 1 = Send to Killstreaker Only, 2 = Display to all", 0, true, 0.0, true, 2.0);

    RegAdminCmd("sm_resetranks", Action_ResetRanks, ADMFLAG_ROOT);

    RegConsoleCmd("sm_rank", Action_ShowRankMenu);
    RegConsoleCmd("sm_ranks", Action_ShowRankMenu);

    HookEvent("player_death", Event_PlayerDeath);

    CreateTimer(300.0, Timer_Message, 0, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

    SQL_SyncDatabase();
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
                    PrintToChatAll("\x04[SNTRanks]: \x01%s is on a killing spree! They get an additional \x05(1.5x) \x01Points!")
                }
                case 10:
                {
                    PrintToChatAll("\x04[SNTRanks]: \x01%s is unstoppable! They get an additional \x05(1.5x) \x01Points!")
                }
                case 15:
                {
                    PrintToChatAll("\x04[SNTRanks]: \x01%s is on a rampage! They get an additional \x05(2x) \x01Points!")
                }
                case 20:
                {
                    PrintToChatAll("\x04[SNTRanks]: \x01%s is god-like! They get an additional \x05(2x) \x01Points!")
                }
            } 
    }
}

public int Top10_Menu_Handler(Menu menu, MenuAction action, int param1, int param2)
{
    switch(action)
    {
        case MenuAction_Select:
        {
            return 0;
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

public void SQL_Top10Menu(Handle owner, Handle hndl, const String:error[], any data)
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
        int i = 0;
        int y = 1;
        char query[512];
        char _cStoredName[64];
        char _cFormatBuffer[128];
        float _fStoredScore;
        Format(query, sizeof(query), "SELECT * FROM snt_playerranks ORDER BY score DESC");
        SQL_TQuery(db, SQL_ErrorLogger, query);
        Menu _mTop10Menu = new Menu(Top10_Menu_Handler, MENU_ACTIONS_DEFAULT);
        _mTop10Menu.SetTitle("SNTRank Top 10")
        while (SQL_FetchRow(hndl))
        {
            i++;
            y++;
            SQL_FetchString(hndl, 1, _cStoredName, sizeof(_cStoredName));
            _fStoredScore = SQL_FetchFloat(hndl, 0);
            switch (i)
            {
                case 1:  Format(_cFormatBuffer, sizeof(_cFormatBuffer), "%s | %ist | %f points", _cStoredName, y, _fStoredScore);
                case 2:  Format(_cFormatBuffer, sizeof(_cFormatBuffer), "%s | %ind | %f points", _cStoredName, y, _fStoredScore);
                case 3:  Format(_cFormatBuffer, sizeof(_cFormatBuffer), "%s | %ird | %f points", _cStoredName, y, _fStoredScore);
                default: Format(_cFormatBuffer, sizeof(_cFormatBuffer), "%s | %ith | %f points", _cStoredName, y, _fStoredScore);
            }
            _mTop10Menu.AddItem("RANK_PLAYER", _cFormatBuffer, ITEMDRAW_DISABLED);
            if (i == 10)
            {
                break;
            }
        }
    }
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
            }
            else if (StrEqual(menuItemBuffer, "OPT_TOGGLEDISPLAY"))
            {
                if (ReturnClientPref(param1))
                {
                    SetClientCookie(param1, g_ckDisplayRank, "disabled");
                }
                else if (!ReturnClientPref(param1))
                {
                    SetClientCookie(param1, g_ckDisplayRank, "enabled");
                }
            }
            else if (StrEqual(menuItemBuffer, "OPT_TOP10"))
            {
                char query[512];
                int client = GetClientUserId(param1);
                delete menu;
                Format(query, sizeof(query), "SELECT * FROM snt_playerranks");
                SQL_TQuery(db, SQL_Top10Menu, query, client);
            }
            else if (StrEqual(menuItemBuffer, "OPT_RESETRANK"))
            {
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
                g_iPlayerKillstreak[client] = 0;
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
        }
        if (!IsFakeClient(client) && !IsFakeClient(attacker) && client != attacker && client != 0 && attacker != 0)
        {
            g_iPlayerKillstreak[attacker]++;
            g_fPlayerScore[attacker] += g_cvPointsKill.FloatValue;
            Format(query, sizeof(query), "UPDATE snt_playerranks SET score=%f WHERE steamid=%s", g_fPlayerScore, _cAttackerAuthId);
            SQL_TQuery(db, SQL_ErrorLogger, query);
            Format(query, sizeof(query), "SELECT * FROM snt_playerranks ORDER BY score DESC");
            SQL_TQuery(db, SQL_ErrorLogger, query);
            if (g_iPlayerKillstreak[client] >= 5)
            {
                g_iPlayerKillstreak[client] = 0;
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

            if (assister != 0 && !IsFakeClient(assister))
            {
                char _cAssisterAuthId[32];
                GetClientAuthId(assister, AuthId_Steam3, _cAssisterAuthId, sizeof(_cAssisterAuthId));
                if (TF2_GetPlayerClass(assister) != TFClass_Medic)
                {
                    g_fPlayerScore[assister] += g_cvPointsAssist.FloatValue;
                    Format(query, sizeof(query), "UPDATE snt_playerranks SET score=%f WHERE steamid=%s", g_fPlayerScore[assister], _cAssisterAuthId);
                    SQL_TQuery(db, SQL_ErrorLogger, query);
                    Format(query, sizeof(query), "SELECT * FROM snt_playerranks ORDER BY score DESC");
                    SQL_TQuery(db, SQL_ErrorLogger, query);
                }
                else
                {
                    g_iPlayerKillstreak[assister]++;
                    g_fPlayerScore[assister] += g_cvPointsAssistMedic.FloatValue;
                    Format(query, sizeof(query), "UPDATE snt_playerranks SET score=%f WHERE steamid=%s", g_fPlayerScore[assister], _cAssisterAuthId);
                    SQL_TQuery(db, SQL_ErrorLogger, query);
                    Format(query, sizeof(query), "SELECT * FROM snt_playerranks ORDER BY score DESC");
                    SQL_TQuery(db, SQL_ErrorLogger, query);
                }
            }
            PrintPlayerKillstreak(attacker);
        }
    }
    return Plugin_Continue;
}

public Action CP_OnChatMessage(int& author, ArrayList recipients, char[] flagstring, char[] name, char[] message, bool & processcolors, bool & removecolors)
{
    char query[512];
    char _cAuthorId[32];
    int _iUserId = GetClientUserId(author);
    GetClientAuthId(author, AuthId_Steam3, _cAuthorId, sizeof(_cAuthorId));
    if (g_bIsEnabled && ReturnClientPref(author))
    {
        Format(query, sizeof(query), "SELECT * FROM snt_playerranks WHERE steamid=%s", _cAuthorId);
        SQL_TQuery(db, SQL_RetreivePlayerRank, query, _iUserId);
        Format(name, MAXLENGTH_NAME, "#%i | %s", g_iPlayerRank, name);
    }
    return Plugin_Changed;
}

public Action:Action_ShowRankMenu(int client, int args)
{
    if(args > 0)
    {
        PrintToChat(client, "\x04[INFO] Usage: \x01/rank or /ranks");
    }
    Menu _mRankMenu = new Menu(Info_Menu_Handler, MENU_ACTIONS_DEFAULT);
    _mRankMenu.SetTitle("SNTRank Menu");
    _mRankMenu.AddItem("OPT_VIEWRANK", "View your current rank info");
    _mRankMenu.AddItem("OPT_RESETRANK", "Reset your current rank");
    _mRankMenu.AddItem("OPT_TOGGLEDISPLAY", "Toggles your rank display")
    _mRankMenu.AddItem("OPT_TOP10", "View the top 10 players");
    _mRankMenu.Display(client, MENU_TIME_FOREVER);
    return Plugin_Handled;
}

public Action:Action_ResetRanks(int client, int args)
{
    if (args < 1 || args > 1)
    {
        ReplyToCommand(client, "\x04[SNTRank] Usage: \x01/resetranks <CONFIRM>");
        return Plugin_Handled;
    }
    char _cArgs[32];
    char query[512];
    GetCmdArg(1, _cArgs, sizeof(_cArgs));
    if (StrEqual(_cArgs, "<CONFIRM>"))
    {
        Format(query, sizeof(query), "UPDATE snt_playerranks SET score=0.0");
        SQL_TQuery(db, SQL_ErrorLogger, query);
        SQL_SyncDatabase();
        ReplyToCommand(client, "\x04[SNTRank]: \x01Successfully reset all scores in the database.");
    }
    return Plugin_Handled;
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
            Format(query, sizeof(query), "SELECT score FROM snt_playerranks WHERE steamid=%s", _cAuthId);
            SQL_TQuery(db, SQL_OnClientConnect, query, _iClientId);
        }
    }
}

public void OnClientDisconnect(int client)
{
    g_fPlayerScore[client] = 0.0;
    g_iPlayerRank[client] = 0;
    g_iPlayerKillstreak[client] = 0;
}