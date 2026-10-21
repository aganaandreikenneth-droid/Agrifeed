// AgriFeed Realtime Database Security Rules: source.
//
// Realtime Database rules have no reusable functions, so the conditions are
// built here from named helpers and expanded by build.mjs into
// database.rules.json (the file the emulator loads and that would be deployed).
//
// Conventions:
//  * Every helper returns a fully parenthesised expression, so combining
//    them with && / || can never change their meaning.
//  * Nothing grants .read/.write on a parent such as feeders/$feederId:
//    a grant on a parent cannot be revoked by its children.
//  * .validate does not run on deletes, so every .write states explicitly
//    whether it allows create (!data.exists()), update or delete
//    (!newData.exists()).
//  * Writes performed by Cloud Functions / Admin SDK bypass these rules; any
//    path with no client .write is backend-only.

const p = (s) => `(${s})`;
const and = (...xs) => p(xs.join(' && '));
const or = (...xs) => p(xs.join(' || '));
const not = (x) => `!${p(x)}`;

const FEEDER = "root.child('feeders').child($feederId)";
const REG = "root.child('deviceRegistry').child($feederId)";
const ME = `${FEEDER}.child('members').child(auth.uid)`;

// --- identities -------------------------------------------------------------

/** A person (not a device) with a verified email. Suspension not checked. */
const isHuman = and('auth != null', 'auth.token.device != true', 'auth.token.email_verified == true');

/** A verified person whose account is not suspended. */
export const isUser = and(isHuman, "root.child('accountStatus').child(auth.uid).child('suspended').val() != true");

/** Platform administrator: custom claim AND backend registry (revocation is immediate). */
export const isAdmin = and(isUser, 'auth.token.admin == true', "root.child('platformAdmins').child(auth.uid).val() == true");

const own = (uidVar) => and(isUser, `auth.uid == ${uidVar}`);

// --- feeder roles (inside feeders/$feederId) --------------------------------

const isActiveMember = and(
  isUser,
  `${ME}.child('status').val() == 'active'`,
  or(not(`${ME}.child('expiresAt').exists()`), `${ME}.child('expiresAt').val() > now`),
);

const isOwner = and(
  isActiveMember,
  `${ME}.child('role').val() == 'owner'`,
  `${FEEDER}.child('meta').child('ownerUid').val() == auth.uid`,
);

/** Owners hold every permission; members only those granted to them. */
const hasPerm = (perm) =>
  or(isOwner, and(isActiveMember, `${ME}.child('role').val() == 'member'`, `${ME}.child('permissions').child('${perm}').val() == true`));

/**
 * The feeder's own device (ESP32 or simulator). Checked live against the
 * registry, so revocation, disabling and credential rotation take effect on
 * the next request even while an older ID token is still unexpired.
 */
const isDevice = and(
  'auth != null',
  'auth.token.device == true',
  'auth.token.feederId == $feederId',
  `auth.uid == ${REG}.child('deviceUid').val()`,
  `${REG}.child('status').val() == 'active'`,
  `auth.token.mode == ${REG}.child('mode').val()`,
  `auth.token.credVersion == ${REG}.child('credentialVersion').val()`,
);

const isSimFeeder = `${REG}.child('mode').val() == 'simulated'`;

/** Device-written records must declare where they came from, matching the feeder mode. */
const sourceMatchesMode = or(
  and(`${REG}.child('mode').val() == 'simulated'`, "newData.child('source').val() == 'simulator'"),
  and(`${REG}.child('mode').val() == 'live'`, "newData.child('source').val() == 'device'"),
);

// --- validation helpers -------------------------------------------------------

const num = (min, max) => and('newData.isNumber()', `newData.val() >= ${min}`, `newData.val() <= ${max}`);
const str = (min, max) => and('newData.isString()', `newData.val().length >= ${min}`, `newData.val().length <= ${max}`);
const oneOf = (...vals) => and('newData.isString()', `newData.val().matches(/^(${vals.join('|')})$/)`);
const isNow = 'newData.val() == now';
const createdNowOrUnchanged = or(and('!data.exists()', isNow), 'newData.val() == data.val()');
const deny = { '.validate': false };

const HARD_MAX_DISPENSE_G = 500; // platform safety cap per request
const COMMAND_TTL_MS = 120000; // a pending command older than this may be expired
const TERMINAL = ['completed', 'partial', 'failed', 'rejected', 'expired'];

const amountWithinLimits = and(
  'newData.isNumber()',
  'newData.val() >= 1',
  `newData.val() <= ${HARD_MAX_DISPENSE_G}`,
  or(not(`${FEEDER}.child('config/maxDispenseG').exists()`), `newData.val() <= ${FEEDER}.child('config/maxDispenseG').val()`),
);

// --- rules tree ----------------------------------------------------------------

export const rules = {
  rules: {
    users: {
      '.read': isAdmin,
      $uid: {
        '.read': own('$uid'),
        // Create once; afterwards only the listed child fields are writable.
        '.write': and(own('$uid'), '!data.exists()', 'newData.exists()'),
        '.validate': "newData.hasChildren(['displayName', 'createdAt'])",
        displayName: { '.write': and(own('$uid'), 'newData.exists()'), '.validate': str(1, 60) },
        createdAt: { '.validate': createdNowOrUnchanged },
        lastSelectedFeederId: {
          '.write': own('$uid'),
          '.validate': and('newData.isString()', "root.child('userFeeders').child($uid).child(newData.val()).exists()"),
        },
        $other: deny,
      },
    },

    // Backend-only. A user may read their own status even while suspended.
    accountStatus: {
      '.read': isAdmin,
      $uid: { '.read': and(isHuman, 'auth.uid == $uid') },
    },
    platformAdmins: { '.read': isAdmin },
    platformAudit: { '.read': isAdmin, '.indexOn': ['ts'] },
    deviceRegistry: { '.read': isAdmin },
    // deviceClaims, invitations: no client access at all (Cloud Functions only).

    userFeeders: {
      $uid: { '.read': own('$uid') },
    },

    notifications: {
      $uid: {
        '.read': own('$uid'),
        '.indexOn': ['ts'],
        $nid: {
          // Dismiss (delete) own notification; content is written by the backend.
          '.write': and(own('$uid'), 'data.exists()', '!newData.exists()'),
          '.validate': "newData.hasChildren(['type', 'title', 'ts'])",
          read: {
            '.write': and(own('$uid'), 'data.parent().exists()', 'newData.exists()'),
            '.validate': 'newData.isBoolean()',
          },
        },
      },
    },

    notificationPreferences: {
      $uid: {
        '.read': own('$uid'),
        '.write': own('$uid'),
        lowFeed: { '.validate': 'newData.isBoolean()' },
        stuckFeed: { '.validate': 'newData.isBoolean()' },
        connectivity: { '.validate': 'newData.isBoolean()' },
        feedingCompleted: { '.validate': 'newData.isBoolean()' },
        feedingFailed: { '.validate': 'newData.isBoolean()' },
        critical: { '.validate': 'newData.isBoolean()' },
        push: { '.validate': 'newData.isBoolean()' },
        $other: deny,
      },
    },

    feeders: {
      $feederId: {
        // ownerUid, mode, createdAt are set by the backend and never by clients.
        meta: {
          '.read': or(isActiveMember, isDevice),
          name: { '.write': and(isOwner, 'newData.exists()'), '.validate': str(1, 40) },
          timezone: {
            '.write': and(isOwner, 'newData.exists()'),
            '.validate': and('newData.isString()', 'newData.val().matches(/^(UTC|[A-Za-z]+\\/[A-Za-z0-9_+-]+(\\/[A-Za-z0-9_+-]+)?)$/)'),
          },
        },

        config: {
          '.read': or(isActiveMember, isDevice),
          capacityG: {
            '.write': and(isOwner, 'newData.exists()'),
            '.validate': and(
              num(100, 50000),
              or(not(`${FEEDER}.child('config/loadCellMaxG').exists()`), `newData.val() <= ${FEEDER}.child('config/loadCellMaxG').val()`),
            ),
          },
          lowThresholdG: {
            '.write': and(isOwner, 'newData.exists()'),
            '.validate': and(
              num(0, 50000),
              or(not("newData.parent().child('capacityG').exists()"), "newData.val() < newData.parent().child('capacityG').val()"),
            ),
          },
          maxDispenseG: { '.write': and(isOwner, 'newData.exists()'), '.validate': num(1, HARD_MAX_DISPENSE_G) },
          schedulesPaused: { '.write': and(hasPerm('manageSchedules'), 'newData.exists()'), '.validate': 'newData.isBoolean()' },
          calibrationStatus: {
            '.write': and(isDevice, 'newData.exists()'),
            '.validate': oneOf('uncalibrated', 'needs-calibration', 'calibrated'),
          },
          // loadCellMaxG: backend only (hardware fact set at registration).
          $other: deny,
        },

        members: {
          '.read': isOwner,
          $uid: { '.read': and(isUser, 'auth.uid == $uid') },
          // Written only by Cloud Functions (invitations, permission changes).
        },

        status: {
          '.read': or(hasPerm('viewDashboard'), isDevice),
          '.write': and(isDevice, 'newData.exists()'),
          '.validate': and("newData.hasChildren(['lastSeen', 'condition', 'source'])", sourceMatchesMode),
          lastSeen: { '.validate': isNow },
          condition: { '.validate': oneOf('ok', 'jam', 'low_feed', 'error', 'unknown') },
          rssi: { '.validate': num(-150, 0) },
          firmware: { '.validate': str(1, 32) },
          source: { '.validate': 'newData.isString()' },
          $other: deny,
        },

        telemetry: {
          '.read': or(hasPerm('viewDashboard'), isDevice),
          current: {
            '.write': and(isDevice, 'newData.exists()'),
            '.validate': and("newData.hasChildren(['weightG', 'measuredAt', 'quality', 'source'])", sourceMatchesMode),
            weightG: { '.validate': num(-500, 100000) },
            measuredAt: { '.validate': isNow },
            quality: { '.validate': oneOf('ok', 'unstable', 'error') },
            source: { '.validate': 'newData.isString()' },
            $other: deny,
          },
        },

        measurements: {
          '.read': or(hasPerm('viewAnalytics'), hasPerm('viewHistory')),
          '.indexOn': ['ts'],
          $mid: {
            '.write': and(isDevice, '!data.exists()', 'newData.exists()'),
            '.validate': and("newData.hasChildren(['weightG', 'ts', 'source'])", sourceMatchesMode),
            weightG: { '.validate': num(-500, 100000) },
            ts: { '.validate': isNow },
            source: { '.validate': 'newData.isString()' },
            $other: deny,
          },
        },

        history: {
          '.read': or(hasPerm('viewHistory'), hasPerm('viewAnalytics')),
          '.indexOn': ['ts'],
          $eid: {
            // Verified outcomes: device-created, never edited or deleted by clients.
            '.write': and(isDevice, '!data.exists()', 'newData.exists()'),
            '.validate': and("newData.hasChildren(['method', 'requestedG', 'status', 'ts', 'source'])", sourceMatchesMode),
            method: { '.validate': oneOf('scheduled', 'manual') },
            requestedG: { '.validate': num(1, HARD_MAX_DISPENSE_G) },
            actualG: { '.validate': num(0, 2000) },
            status: { '.validate': oneOf(...TERMINAL) },
            ts: { '.validate': isNow },
            commandId: { '.validate': str(1, 64) },
            scheduleId: { '.validate': str(1, 64) },
            source: { '.validate': 'newData.isString()' },
            $other: deny,
          },
        },

        alerts: {
          '.read': hasPerm('viewDashboard'),
          '.indexOn': ['lastAt'],
          $aid: {
            '.write': and(isDevice, 'newData.exists()'),
            '.validate': and("newData.hasChildren(['type', 'severity', 'state', 'firstAt', 'lastAt', 'source'])", sourceMatchesMode),
            type: { '.validate': oneOf('low_feed', 'stuck_feed', 'sensor_error', 'dispense_failed') },
            severity: { '.validate': oneOf('info', 'warning', 'critical') },
            state: { '.validate': oneOf('active', 'resolved') },
            firstAt: { '.validate': or(and('!data.exists()', isNow), 'newData.val() == data.val()') },
            lastAt: { '.validate': isNow },
            source: { '.validate': 'newData.isString()' },
            $other: deny,
          },
        },

        audit: {
          '.read': isOwner,
          '.indexOn': ['ts'],
          // Backend only.
        },

        schedules: {
          '.read': or(hasPerm('viewDashboard'), hasPerm('manageSchedules'), isDevice),
          $sid: {
            '.write': hasPerm('manageSchedules'), // create, edit and delete
            '.validate': "newData.hasChildren(['time', 'weekdays', 'amountG', 'enabled', 'createdAt', 'updatedAt', 'updatedBy'])",
            time: { '.validate': and('newData.isString()', 'newData.val().matches(/^([01][0-9]|2[0-3]):[0-5][0-9]$/)') },
            weekdays: {
              $day: { '.validate': and('$day.matches(/^[0-6]$/)', 'newData.isBoolean()') },
            },
            amountG: { '.validate': amountWithinLimits },
            enabled: { '.validate': 'newData.isBoolean()' },
            label: { '.validate': str(1, 40) },
            createdAt: { '.validate': createdNowOrUnchanged },
            updatedAt: { '.validate': isNow },
            updatedBy: { '.validate': 'newData.val() == auth.uid' },
            $other: deny,
          },
        },

        // One dispense at a time: a command is created together with this lock.
        activeCommand: {
          '.read': or(hasPerm('manualFeed'), hasPerm('viewDashboard'), isDevice),
          '.write': or(
            and(
              hasPerm('manualFeed'),
              '!data.exists()',
              'newData.exists()',
              "!data.parent().child('commands').child(newData.child('commandId').val()).exists()",
              "newData.parent().child('commands').child(newData.child('commandId').val()).child('requestedBy').val() == auth.uid",
            ),
            and(isDevice, 'data.exists()', '!newData.exists()'),
            // Release the lock once its command has finished or been expired.
            and(
              hasPerm('manualFeed'),
              'data.exists()',
              '!newData.exists()',
              `newData.parent().child('commands').child(data.child('commandId').val()).child('status').val().matches(/^(${TERMINAL.join('|')})$/)`,
            ),
          ),
          '.validate': "newData.hasChildren(['commandId', 'requestedAt'])",
          commandId: { '.validate': str(1, 64) },
          requestedAt: { '.validate': isNow },
          $other: deny,
        },

        commands: {
          '.read': or(hasPerm('manualFeed'), hasPerm('viewHistory'), isDevice),
          '.indexOn': ['requestedAt'],
          $cid: {
            '.write': or(
              // 1. An authorised user requests feeding (requires taking the lock).
              and(
                hasPerm('manualFeed'),
                '!data.exists()',
                'newData.exists()',
                `!${FEEDER}.child('activeCommand').exists()`,
                "newData.parent().parent().child('activeCommand/commandId').val() == $cid",
              ),
              // 2. The feeder reports progress and the measured outcome.
              and(isDevice, 'data.exists()', 'newData.exists()'),
              // 3. The requester (or owner) expires a command the feeder never picked up.
              and(
                or(isOwner, and(hasPerm('manualFeed'), "data.child('requestedBy').val() == auth.uid")),
                'data.exists()',
                'newData.exists()',
                "data.child('status').val() == 'pending'",
                `data.child('requestedAt').val() + ${COMMAND_TTL_MS} < now`,
                "newData.child('status').val() == 'expired'",
              ),
            ),
            '.validate': "newData.hasChildren(['amountG', 'requestedBy', 'requestedAt', 'status', 'source'])",
            amountG: { '.validate': or(and('!data.exists()', amountWithinLimits), 'newData.val() == data.val()') },
            requestedBy: { '.validate': or(and('!data.exists()', 'newData.val() == auth.uid'), 'newData.val() == data.val()') },
            requestedAt: { '.validate': createdNowOrUnchanged },
            source: { '.validate': or(and('!data.exists()', "newData.val() == 'app'"), 'newData.val() == data.val()') },
            status: {
              '.validate': or(
                and('!data.exists()', "newData.val() == 'pending'"),
                'newData.val() == data.val()',
                and("data.val() == 'pending'", "newData.val().matches(/^(accepted|rejected|expired)$/)"),
                and("data.val() == 'accepted'", "newData.val().matches(/^(dispensing|failed|expired)$/)"),
                and("data.val() == 'dispensing'", "newData.val().matches(/^(completed|partial|failed)$/)"),
              ),
            },
            // Outcome fields: only the feeder's own device may write them.
            actualG: { '.validate': and('auth.token.device == true', num(0, 2000)) },
            acceptedAt: { '.validate': and('auth.token.device == true', createdNowOrUnchanged) },
            completedAt: { '.validate': and('auth.token.device == true', createdNowOrUnchanged) },
            reason: { '.validate': and('auth.token.device == true', str(1, 120)) },
            executedBy: {
              '.validate': and(
                'auth.token.device == true',
                or(and(isSimFeeder, "newData.val() == 'simulator'"), and(not(isSimFeeder), "newData.val() == 'device'")),
              ),
            },
            $other: deny,
          },
        },

        // Test controls for virtual feeders only. Real feeders reject them.
        simulator: {
          controls: {
            '.read': and(isSimFeeder, or(isOwner, isDevice)),
            '.write': and(isSimFeeder, isOwner),
            hopperWeightG: { '.validate': num(0, 100000) },
            connected: { '.validate': 'newData.isBoolean()' },
            jam: { '.validate': 'newData.isBoolean()' },
            failureRate: { '.validate': num(0, 1) },
            scenario: { '.validate': str(1, 40) },
            updatedAt: { '.validate': isNow },
            $other: deny,
          },
        },
      },
    },
  },
};

export const constants = { HARD_MAX_DISPENSE_G, COMMAND_TTL_MS };
