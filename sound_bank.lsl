// ============================================================
// sound_bank.lsl  —  Audioscape shared sound layer  (LSL)
// ------------------------------------------------------------
// Maps EVENT/STATE KEYS -> sounds. Controllers (GoL board, life-spheres)
// never hold sound UUIDs; they fire a link message "play the <key> sound"
// and this script does the lookup + playback.
//
// STORAGE: the notecard "Sound Bank" is parsed ONCE into Linkset Data
// (LSD). Notecard reads are slow (async dataserver, one line at a time);
// LSD reads are synchronous and fast. Because LSD persists across script
// resets, a reset re-reads instantly and re-parses the notecard ONLY when
// it actually changed (CHANGED_INVENTORY) or on an explicit "@reload".
//   (LSD requires current Second Life. Some OpenSim grids lack it.)
//
// ---- Controller -> bank protocol ---------------------------------------
//   llMessageLinked(LINK_THIS, LM_SOUND, "<key>", NULL_KEY);
//   llMessageLinked(LINK_THIS, LM_SOUND, "<key>|<volume>", NULL_KEY);  // 0.0-1.0
// Reserved control keys:
//   "@stop"    -> llStopSound() on this prim (attached/looping sound)
//   "@reload"  -> wipe our LSD + re-read the notecard
//
// Reach this script in the ROOT with LINK_THIS / LINK_ROOT / LINK_SET
// (NOT LINK_ALL_CHILDREN — that excludes the root).
// ============================================================

integer LM_SOUND   = 5001;         // controller -> bank : "<key>[|<vol>]"
string  NOTECARD   = "Sound Bank"; // inventory notecard this bank reads
integer DEBUG_CHAN = 42;           // owner-only audition: "/42 <key>". 0 = off.
string  PREFIX     = "sb:";        // LSD namespace for our keys
string  MARK       = "sb:__loaded";// LSD marker: notecard already parsed

// Playback mode codes (stored as the last CSV field of each pool record).
integer MODE_TRIGGER = 0;  // llTriggerSound - detached, survives obj death, one-shot
integer MODE_PLAY    = 1;  // llPlaySound    - attached to this prim (spatial), replaces prior
integer MODE_LOOP    = 2;  // llLoopSound    - ambient loop until @stop / another loop

// Notecard read state (only used during a parse).
integer gLine;
key     gQuery;
integer gListen;

// -- parse one mode word -> mode code ------------------------------------
integer modeCode(string m) {
    m = llToLower(llStringTrim(m, STRING_TRIM));
    if (m == "play") return MODE_PLAY;
    if (m == "loop") return MODE_LOOP;
    return MODE_TRIGGER; // default & "trigger"
}

// -- append one "uuid,vol,mode" record to a key's pool in LSD ------------
appendSound(string k, string rec) {
    string cur = llLinksetDataRead(PREFIX + k);
    if (cur != "") cur += ";";
    llLinksetDataWrite(PREFIX + k, cur + rec);
}

// -- drop everything this bank wrote to LSD ------------------------------
wipeLSD() {
    llLinksetDataDeleteFound("^" + PREFIX, ""); // regex over key names, no pass
}

// -- preload every distinct UUID (read straight from LSD, no notecard) ---
// llPreloadSound is throttled (~1/sec) — fine for a handful of sounds.
preloadAll() {
    integer total = llLinksetDataCountKeys();
    list    keys  = llLinksetDataListKeys(0, total);
    list    seen;
    integer i;
    integer n = llGetListLength(keys);
    for (i = 0; i < n; ++i) {
        string kk = llList2String(keys, i);
        if (kk != MARK && llSubStringIndex(kk, PREFIX) == 0) {
            list recs = llParseString2List(llLinksetDataRead(kk), [";"], []);
            integer j;
            integer rn = llGetListLength(recs);
            for (j = 0; j < rn; ++j) {
                string u = llList2String(llParseString2List(llList2String(recs, j), [","], []), 0);
                if (llListFindList(seen, [u]) == -1) {
                    seen += u;
                    llPreloadSound((key)u);
                }
            }
        }
    }
}

// -- begin (re)parsing the notecard into LSD -----------------------------
loadNotecard() {
    wipeLSD();
    if (llGetInventoryType(NOTECARD) != INVENTORY_NOTECARD) {
        llOwnerSay("[sound] No notecard named \"" + NOTECARD + "\" in inventory.");
        return;
    }
    gLine  = 0;
    gQuery = llGetNotecardLine(NOTECARD, gLine);
}

// -- play the sound(s) registered under a key ----------------------------
// volOverride < 0 means "use the stored volume".
playKey(string k, float volOverride) {
    if (k == "@stop")   { llStopSound();  return; }
    if (k == "@reload") { loadNotecard(); return; }

    string pool = llLinksetDataRead(PREFIX + k);
    if (pool == "") return; // no mapping for this key — stay quiet

    list    recs = llParseString2List(pool, [";"], []);
    string  rec  = llList2String(recs, (integer)llFrand(llGetListLength(recs))); // random pick
    list    f    = llParseString2List(rec, [","], []);
    key     u    = (key)llList2String(f, 0);
    float   vol  = (float)llList2String(f, 1);
    integer mode = (integer)llList2String(f, 2);
    if (volOverride >= 0.0) vol = volOverride;

    if (mode == MODE_PLAY)      llPlaySound(u, vol);
    else if (mode == MODE_LOOP) llLoopSound(u, vol);
    else                        llTriggerSound(u, vol);
}

default {
    state_entry() {
        if (DEBUG_CHAN != 0) gListen = llListen(DEBUG_CHAN, "", llGetOwner(), "");
        // Fast path: notecard already parsed into LSD on a previous run.
        if (llLinksetDataRead(MARK) == "1") preloadAll();
        else                                loadNotecard();
    }

    // Notecard reader: one line per dataserver callback (parse only).
    dataserver(key q, string data) {
        if (q != gQuery) return;
        if (data == EOF) {
            llLinksetDataWrite(MARK, "1");
            preloadAll();
            llOwnerSay("[sound] parsed \"" + NOTECARD + "\" into linkset data.");
            return;
        }
        string line = llStringTrim(data, STRING_TRIM);
        if (line != "" && llGetSubString(line, 0, 0) != "#") {
            // key | uuid | volume | mode   (volume & mode optional)
            list   f = llParseString2List(line, ["|"], []);
            string k = llStringTrim(llList2String(f, 0), STRING_TRIM);
            key    u = (key)llStringTrim(llList2String(f, 1), STRING_TRIM);
            // Nest the checks: a key can't be an operand of && (integers only);
            // a key alone in an if() is TRUE only for a valid, non-null UUID.
            if (k == "") {
                llOwnerSay("[sound] skipped (no key): " + line);
            } else if (u) {                 // key alone = TRUE only for a valid, non-null UUID
                float   vol  = 1.0;
                integer mode = MODE_TRIGGER;
                if (llGetListLength(f) > 2) {
                    string vs = llStringTrim(llList2String(f, 2), STRING_TRIM);
                    if (vs != "") vol = (float)vs;
                }
                if (llGetListLength(f) > 3) mode = modeCode(llList2String(f, 3));
                appendSound(k, (string)u + "," + (string)vol + "," + (string)mode);
            } else {
                llOwnerSay("[sound] skipped (bad uuid): " + line);
            }
        }
        gQuery = llGetNotecardLine(NOTECARD, ++gLine);
    }

    // Controllers speak to the bank here.
    link_message(integer sender, integer num, string str, key id) {
        if (num != LM_SOUND) return;
        list   f = llParseStringKeepNulls(str, ["|"], []);
        string k = llList2String(f, 0);
        float  v = -1.0;
        if (llGetListLength(f) > 1) {
            string vs = llStringTrim(llList2String(f, 1), STRING_TRIM);
            if (vs != "") v = (float)vs;
        }
        playKey(k, v);
    }

    // Owner audition: "/42 birth"  (or "/42 @stop").
    listen(integer chan, string name, key id, string msg) {
        playKey(llStringTrim(msg, STRING_TRIM), -1.0);
    }

    // Re-parse whenever the notecard is edited/replaced.
    changed(integer c) {
        if (c & CHANGED_INVENTORY) loadNotecard();
    }
}
