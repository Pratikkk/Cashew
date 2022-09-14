import 'dart:convert';
import 'dart:developer';

import 'package:budget/colors.dart';
import 'package:budget/database/binary_string_conversion.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/main.dart';
import 'package:budget/pages/accountsPage.dart';
import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/pages/settingsPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/dropdownSelect.dart';
import 'package:budget/widgets/moreIcons.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/popupFramework.dart';
import 'package:budget/widgets/progressBar.dart';
import 'package:budget/widgets/settingsContainers.dart';
import 'package:budget/widgets/tappable.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:drift/drift.dart' hide Column hide Table;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis/gmail/v1.dart' as gMail;
import 'package:google_sign_in/google_sign_in.dart' as signIn;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_html/html.dart' as html;
import 'dart:math' as math;
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

Future<bool> checkConnection() async {
  late bool isConnected;
  if (!kIsWeb) {
    try {
      final result = await InternetAddress.lookup('example.com');
      if (result.isNotEmpty && result[0].rawAddress.isNotEmpty) {
        isConnected = true;
      }
    } on SocketException catch (e) {
      print(e.toString());
      isConnected = false;
    }
  } else {
    isConnected = true;
  }
  return isConnected;
}

class GoogleAuthClient extends http.BaseClient {
  final Map<String, String> _headers;
  final http.Client _client = new http.Client();
  GoogleAuthClient(this._headers);
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return _client.send(request..headers.addAll(_headers));
  }
}

class AccountAndBackup extends StatefulWidget {
  const AccountAndBackup({Key? key}) : super(key: key);

  @override
  State<AccountAndBackup> createState() => _AccountAndBackupState();
}

signIn.GoogleSignInAccount? user;
late signIn.GoogleSignIn googleSignIn;

Future<bool> signInGoogle(context,
    {bool? waitForCompletion,
    bool? drivePermissions,
    bool? gMailPermissions,
    bool? silentSignIn,
    Function()? next}) async {
  bool isConnected = false;

  try {
    //Check connection
    // isConnected = await checkConnection().timeout(Duration(milliseconds: 2500),
    //     onTimeout: () {
    //   throw ("There was an error checking your connection");
    // });
    // if (isConnected == false) {
    //   if (context != null) {
    //     openSnackbar(context, "Could not connect to network",
    //         backgroundColor: lightenPastel(Theme.of(context).colorScheme.error,
    //             amount: 0.6));
    //   }
    //   return false;
    // }

    if (waitForCompletion == true) openLoadingPopup(context);
    if (user == null) {
      googleSignIn = signIn.GoogleSignIn.standard(scopes: [
        ...(drivePermissions == true ? [drive.DriveApi.driveAppdataScope] : []),
        ...(gMailPermissions == true ? [gMail.GmailApi.gmailReadonlyScope] : [])
      ]);
      final signIn.GoogleSignInAccount? account = silentSignIn == true
          ? await googleSignIn.signInSilently()
          : await googleSignIn.signIn();
      if (account != null) {
        user = account;
      } else {
        throw ("Login failed");
      }
    }
    if (waitForCompletion == true) Navigator.of(context).pop();
    next != null ? next() : 0;
    return true;
  } catch (e) {
    if (waitForCompletion == true) Navigator.of(context).pop();
    openSnackbar(context, e.toString(), isErrorColor: true);
    return false;
  }
}

Future<bool> signOutGoogle() async {
  await googleSignIn.signOut();
  user = null;
  print("Signedout");
  return true;
}

Future<void> createBackupInBackground(context) async {
  print(entireAppLoaded);
  //Only run this once, don't run again if the global state changes (e.g. when changing a setting)
  if (entireAppLoaded == false) {
    if (appStateSettings["autoBackups"] == true) {
      DateTime lastUpdate = DateTime.parse(appStateSettings["lastBackup"]);

      if (lastUpdate.day != DateTime.now().day ||
          lastUpdate.month != DateTime.now().month ||
          lastUpdate.year != DateTime.now().year) {
        print("auto backing up");

        bool hasSignedIn = false;
        if (user == null) {
          hasSignedIn = await signInGoogle(context,
              gMailPermissions: true,
              waitForCompletion: false,
              silentSignIn: true);
        } else {
          hasSignedIn = true;
        }
        if (hasSignedIn == false) {
          return;
        }
        await deleteRecentBackups(context, 10, silentDelete: true);
        await createBackup(context, silentBackup: true);
      } else {
        print("backup already made today");
      }
    }
  }
  return;
}

Future<void> createBackup(context, {bool? silentBackup}) async {
  // Backup user settings
  try {
    final prefs = await SharedPreferences.getInstance();
    String userSettings = prefs.getString('userSettings') ?? "";
    if (userSettings == "") throw ("No settings stored");
    await database.createOrUpdateSettings(
      AppSetting(
        settingsPk: 0,
        settingsJSON: userSettings,
        dateUpdated: DateTime.now(),
      ),
    );
    print("successfully created settings entry");
  } catch (_) {}

  try {
    if (silentBackup == false || silentBackup == null) {
      openLoadingPopup(context);
    }
    var dbFileBytes;
    late Stream<List<int>> mediaStream;
    if (kIsWeb) {
      final html.Storage localStorage = html.window.localStorage;
      dbFileBytes = bin2str.decode(localStorage["moor_db_str_db"] ?? "");
      mediaStream = Stream.value(dbFileBytes);
    } else {
      final dbFolder = await getApplicationDocumentsDirectory();
      final dbFile = File(p.join(dbFolder.path, 'db.sqlite'));
      // Share.shareFiles([p.join(dbFolder.path, 'db.sqlite')],
      //     text: 'Database');
      // await file.readAsBytes();
      dbFileBytes = await dbFile.readAsBytes();
      mediaStream = Stream.value(List<int>.from(dbFileBytes));
    }
    final authHeaders = await user!.authHeaders;
    final authenticateClient = GoogleAuthClient(authHeaders);
    final driveApi = drive.DriveApi(authenticateClient);

    var media = new drive.Media(mediaStream, dbFileBytes.length);

    var driveFile = new drive.File();
    final timestamp =
        DateFormat("yyyy-MM-dd-hhmmss").format(DateTime.now().toUtc());
    driveFile.name = "db-$timestamp.sqlite";
    driveFile.modifiedTime = DateTime.now().toUtc();
    driveFile.parents = ["appDataFolder"];

    await driveApi.files.create(driveFile, uploadMedia: media);
    if (silentBackup == false || silentBackup == null) {
      Navigator.of(context).pop();
    }
    openSnackbar(context, "Backup created: " + (driveFile.name ?? ""));

    updateSettings("lastBackup", DateTime.now().toString(),
        pagesNeedingRefresh: [], updateGlobalState: false);
  } catch (e) {
    if (silentBackup == false || silentBackup == null) {
      Navigator.of(context).pop();
    }
    openSnackbar(context, e.toString());
  }
}

Future<void> deleteRecentBackups(context, amountToKeep,
    {bool? silentDelete}) async {
  try {
    if (silentDelete == false || silentDelete == null) {
      openLoadingPopup(context);
    }

    final authHeaders = await user!.authHeaders;
    final authenticateClient = GoogleAuthClient(authHeaders);
    final driveApi = drive.DriveApi(authenticateClient);
    if (driveApi == null) {
      throw "Failed to login to Google Drive";
    }

    final fileList = await driveApi.files.list(
        spaces: 'appDataFolder', $fields: 'files(id, name, modifiedTime)');
    final files = fileList.files;
    if (files == null) {
      throw "No backups found.";
    }

    int index = 0;
    files.forEach((file) {
      if (index >= amountToKeep) {
        deleteBackup(driveApi, file.id ?? "");
      }
      index++;
    });
    if (silentDelete == false || silentDelete == null) {
      Navigator.of(context).pop();
    }
  } catch (e) {
    if (silentDelete == false || silentDelete == null) {
      Navigator.of(context).pop();
    }
    openSnackbar(context, e.toString());
  }
}

Future<void> deleteBackup(drive.DriveApi driveApi, String fileId) async {
  await driveApi.files.delete(fileId);
}

class _AccountAndBackupState extends State<AccountAndBackup> {
  Future<void> _loadBackup(drive.DriveApi driveApi, String fileId) async {
    try {
      openLoadingPopup(context);

      List<int> dataStore = [];
      dynamic response = await driveApi.files
          .get(fileId, downloadOptions: drive.DownloadOptions.fullMedia);
      response.stream.listen(
        (data) {
          print("Data: ${data.length}");
          dataStore.insertAll(dataStore.length, data);
        },
        onDone: () async {
          if (kIsWeb) {
            final html.Storage localStorage = html.window.localStorage;
            localStorage["moor_db_str_db"] =
                bin2str.encode(Uint8List.fromList(dataStore));
          } else {
            final dbFolder = await getApplicationDocumentsDirectory();
            final dbFile = File(p.join(dbFolder.path, 'db.sqlite'));
            await dbFile.writeAsBytes(dataStore);
            // Share.shareFiles([p.join(dbFolder.path, 'db.sqlite')],
            //     text: 'Database');
          }

          Navigator.of(context).pop();

          await updateSettings("databaseJustImported", true,
              pagesNeedingRefresh: [], updateGlobalState: false);
          print(appStateSettings);

          openPopup(
            context,
            title: "Please Restart the Application",
            barrierDismissible: false,
            icon: Icons.restart_alt_rounded,
          );
        },
        onError: (error) {
          openSnackbar(context, error.toString());
        },
      );
    } catch (e) {
      Navigator.of(context).pop();
      openSnackbar(context, e.toString());
    }
  }

  Future<void> _chooseBackup() async {
    try {
      openLoadingPopup(context);

      final authHeaders = await user!.authHeaders;
      final authenticateClient = GoogleAuthClient(authHeaders);
      final driveApi = drive.DriveApi(authenticateClient);
      if (driveApi == null) {
        throw "Failed to login to Google Drive";
      }

      final fileList = await driveApi.files.list(
          spaces: 'appDataFolder', $fields: 'files(id, name, modifiedTime)');
      final files = fileList.files;
      if (files == null) {
        throw "No backups found.";
      }

      Navigator.of(context).pop();

      openBottomSheet(
        context,
        PopupFramework(
          title: "Choose a Backup to Restore",
          child: Column(
            children: files
                .map(
                  (file) => Padding(
                    padding: const EdgeInsets.only(bottom: 8.0),
                    child: Tappable(
                      onTap: () {
                        _loadBackup(driveApi, file.id ?? "");
                      },
                      borderRadius: 15,
                      color: Theme.of(context).colorScheme.lightDarkAccentHeavy,
                      child: Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: 20, vertical: 15),
                          child: Row(
                            children: [
                              Icon(
                                Icons.description_rounded,
                                color: Theme.of(context).colorScheme.secondary,
                                size: 30,
                              ),
                              SizedBox(width: 13),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  TextFont(
                                    text: getWordedDateShortMore(
                                        (file.modifiedTime ?? DateTime.now())
                                            .toLocal(),
                                        includeTimeIfToday: true),
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  TextFont(
                                      text: file.name ?? "No name",
                                      fontSize: 15),
                                ],
                              ),
                            ],
                          )),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      );
    } catch (e) {
      Navigator.of(context).pop();
      openSnackbar(context, e.toString());
    }
  }

  _getHeaderIndex(List<String> headers, String header) {
    int index = 0;
    for (String headerEntry in headers) {
      if (header == headerEntry) {
        return index;
      }
      index++;
    }
    return -1;
  }

  Future<void> _chooseBackupFile() async {
    try {
      openLoadingPopup(context);

      FilePickerResult? result = await FilePicker.platform.pickFiles(
        allowedExtensions: ['csv'],
        type: FileType.custom,
      );

      if (result != null) {
        File file = File(result.files.single.path ?? "");
        String fileString = await file.readAsString();
        List<List<String>> fileContents = CsvToListConverter()
            .convert(fileString, eol: '\n', shouldParseNumbers: false);
        List<String> headers = fileContents[0];
        List<String> firstEntry = fileContents[1];

        Navigator.of(context).pop();

        Map<String, Map<String, dynamic>> assignedColumns = {
          "date": {
            "displayName": "Date",
            "headerValues": ["date"],
            "required": true,
            "setHeaderValue": "",
            "setHeaderIndex": -1,
          },
          "amount": {
            "displayName": "Amount",
            "headerValues": ["amount"],
            "required": true,
            "setHeaderValue": "",
            "setHeaderIndex": -1,
          },
          "category": {
            "displayName": "Category",
            "headerValues": ["category", "category name"],
            // "extraOptions": ["Use Smart Categories"],
            //This will be implemented later... in the future
            //Use title to determine category. If smart category entry not found, ask user to select which category when importing. Save these selections to that category.
            "required": true,
            "setHeaderValue": "",
            "setHeaderIndex": -1,
          },
          "name": {
            "displayName": "Title",
            "headerValues": ["title", "name"],
            "required": false,
            "setHeaderValue": "",
            "setHeaderIndex": -1,
          },
          "note": {
            "displayName": "Note",
            "headerValues": ["note"],
            "required": false,
            "setHeaderValue": "",
            "setHeaderIndex": -1,
          },
          "wallet": {
            "displayName": "Wallet",
            "headerValues": ["wallet"],
            "required": true,
            "setHeaderValue": "",
            "setHeaderIndex": -1,
            "canSelectCurrentWallet": true,
          },
        };
        for (dynamic key in assignedColumns.keys) {
          String setHeaderValue = determineInitialValue(
              assignedColumns[key]!["headerValues"],
              headers,
              assignedColumns[key]!["required"],
              assignedColumns[key]!["canSelectCurrentWallet"]);
          assignedColumns[key]!["setHeaderValue"] = setHeaderValue;
          assignedColumns[key]!["setHeaderIndex"] =
              _getHeaderIndex(headers, setHeaderValue);
        }

        openBottomSheet(
          context,
          PopupFramework(
            title: "Assign Columns",
            child: Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.vertical,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Table(
                        defaultColumnWidth: IntrinsicColumnWidth(),
                        defaultVerticalAlignment:
                            TableCellVerticalAlignment.middle,
                        children: <TableRow>[
                          TableRow(
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .secondaryContainer,
                            ),
                            children: <Widget>[
                              for (dynamic header in headers)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 11.0, vertical: 5),
                                  child: TextFont(
                                    text: header.toString(),
                                    fontWeight: FontWeight.bold,
                                  ),
                                )
                            ],
                          ),
                          TableRow(
                            decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .lightDarkAccentHeavy),
                            children: <Widget>[
                              for (dynamic entry in firstEntry)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 11.0, vertical: 5),
                                  child: TextFont(
                                    text: entry.toString(),
                                    fontSize: 18,
                                  ),
                                )
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 15),
                  child: Column(
                    children: [
                      for (dynamic key in assignedColumns.keys)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 5),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              TextFont(
                                text: assignedColumns[key]!["displayName"]
                                    .toString(),
                                fontSize: 15,
                              ),
                              DropdownSelect(
                                compact: true,
                                initial:
                                    assignedColumns[key]!["setHeaderValue"],
                                items: assignedColumns[key]![
                                            "canSelectCurrentWallet"] ==
                                        true
                                    ? ["~Current Wallet~", ...headers]
                                    : assignedColumns[key]!["required"]
                                        ? [
                                            ...(assignedColumns[key]![
                                                        "setHeaderValue"] ==
                                                    ""
                                                ? [""]
                                                : []),
                                            ...headers
                                          ]
                                        : ["~None~", ...headers],
                                boldedValues: ["~Current Wallet~", "~None~"],
                                onChanged: (String setHeaderValue) {
                                  assignedColumns[key]!["setHeaderValue"] =
                                      setHeaderValue;
                                  assignedColumns[key]!["setHeaderIndex"] =
                                      _getHeaderIndex(headers, setHeaderValue);
                                },
                                backgroundColor: Theme.of(context).canvasColor,
                                checkInitialValue: true,
                              ),
                            ],
                          ),
                        )
                    ],
                  ),
                ),
                Button(
                  label: "Import",
                  onTap: () async {
                    _importEntries(assignedColumns, fileContents);
                  },
                )
              ],
            ),
          ),
        );
      } else {
        throw "No file selected";
      }
    } catch (e) {
      Navigator.of(context).pop();
      openSnackbar(context, e.toString());
    }
  }

  Future<void> _importEntries(Map<String, Map<String, dynamic>> assignedColumns,
      List<List<String>> fileContents) async {
    try {
      //Check to see if all the required parameters have been set
      for (dynamic key in assignedColumns.keys) {
        if (assignedColumns[key]!["setHeaderValue"] == "") {
          throw "Please make sure you select a parameter for each required field.";
        }
        print(assignedColumns[key]!["setHeaderIndex"]);
      }
    } catch (e) {
      throw (e.toString());
    }
    Navigator.of(context).pop();
    // Open the progress bar
    // This Widget opened will actually do the importing
    openPopupCustom(
      context,
      title: "Importing...",
      child: ImportingEntriesPopup(
        assignedColumns: assignedColumns,
        fileContents: fileContents,
        next: () {
          Navigator.of(context).pop();
          openPopup(
            context,
            icon: Icons.check_circle_outline_rounded,
            title: "Done!",
            description: "Successfully imported " +
                fileContents.length.toString() +
                " transactions.",
            onSubmitLabel: "OK",
            onSubmit: () {
              Navigator.pop(context);
            },
            barrierDismissible: false,
          );
        },
      ),
      barrierDismissible: false,
    );
    return;
  }

  String determineInitialValue(List<String> headerValues, List<String> headers,
      bool required, bool? canSelectCurrentWallet) {
    for (String header in headers) {
      if (headerValues.contains(header.toLowerCase())) {
        return header;
      }
    }
    if (canSelectCurrentWallet == true) {
      return "~Current Wallet~";
    }
    if (!required) {
      return "~None~";
    }
    return "";
  }

  @override
  Widget build(BuildContext context) {
    final Widget accountsPage = AccountsPage(
      exportData: () async {
        await deleteRecentBackups(context, 10);
        await createBackup(context);
      },
      importData: () async {
        await _chooseBackup();
      },
      logout: () async {
        final result = await signOutGoogle();
        if (result) Navigator.pop(context);
        setState(() {});
      },
    );
    return Column(
      children: [
        user == null
            ? SettingsContainer(
                onTap: () async {
                  await signInGoogle(context,
                      waitForCompletion: true,
                      drivePermissions: true, next: () {
                    setState(() {});
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => accountsPage),
                    );
                  });
                },
                title: "Login",
                icon: MoreIcons.google,
              )
            : SettingsContainerOpenPage(
                openPage: accountsPage,
                title: user!.displayName ?? "",
                icon: Icons.account_circle),
        AnimatedSize(
          duration: Duration(milliseconds: 400),
          curve: Curves.easeInOut,
          child: AnimatedSwitcher(
            duration: Duration(milliseconds: 300),
            child: user == null
                ? SizedBox.shrink()
                : SettingsContainerSwitch(
                    onSwitched: (value) {
                      updateSettings("autoBackups", value,
                          pagesNeedingRefresh: [], updateGlobalState: false);
                    },
                    initialValue: appStateSettings["autoBackups"],
                    title: "Auto Backups",
                    description: "Backup data daily when opened",
                    icon: Icons.backup_rounded,
                  ),
          ),
        ),
        SettingsContainer(
          onTap: () async {
            await _chooseBackupFile();
          },
          title: "Import CSV File",
          icon: Icons.file_open_rounded,
        ),
      ],
    );
  }
}

class ImportingEntriesPopup extends StatefulWidget {
  const ImportingEntriesPopup({
    required this.assignedColumns,
    required this.fileContents,
    required this.next,
    Key? key,
  }) : super(key: key);

  final Map<String, Map<String, dynamic>> assignedColumns;
  final List<List<String>> fileContents;
  final VoidCallback next;

  @override
  State<ImportingEntriesPopup> createState() => _ImportingEntriesPopupState();
}

class _ImportingEntriesPopupState extends State<ImportingEntriesPopup> {
  double currentPercent = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _importEntries(widget.assignedColumns, widget.fileContents));
  }

  Future<void> _importEntry(Map<String, Map<String, dynamic>> assignedColumns,
      List<String> row, int i) async {
    int transactionPk = 0;
    transactionPk = DateTime.now().millisecondsSinceEpoch;

    String name = "";
    if (assignedColumns["name"]!["setHeaderIndex"] != -1) {
      name = row[assignedColumns["name"]!["setHeaderIndex"]].toString();
    }

    double amount = 0;
    amount = double.parse(row[assignedColumns["amount"]!["setHeaderIndex"]]);

    String note = "";
    if (assignedColumns["note"]!["setHeaderIndex"] != -1) {
      note = row[assignedColumns["note"]!["setHeaderIndex"]].toString();
    }

    int categoryFk = 0;
    TransactionCategory selectedCategory;
    try {
      selectedCategory = await database.getCategoryInstanceGivenName(
          row[assignedColumns["category"]!["setHeaderIndex"]]);
    } catch (_) {
      // category not found, check titles
      try {
        if (name != "") {
          List result = await getRelatingAssociatedTitle(name);
          TransactionAssociatedTitle? associatedTitle = result[0];
          if (associatedTitle == null) {
            throw ("Can't find a category that matched this title: " + name);
          }
          selectedCategory =
              await database.getCategoryInstance(associatedTitle.categoryFk);
        } else {
          throw ("error, just make a new category");
        }
      } catch (e) {
        // print(e.toString());
        // just create a category
        int numberOfCategories =
            (await database.getTotalCountOfCategories())[0] ?? 0;
        await database.createOrUpdateCategory(
          TransactionCategory(
            categoryPk: DateTime.now().millisecondsSinceEpoch,
            name: row[assignedColumns["category"]!["setHeaderIndex"]],
            dateCreated: DateTime.now(),
            order: numberOfCategories,
            colour: toHexString(
                getSettingConstants(appStateSettings)["accentColor"]),
            income: amount > 0,
            iconName: "image.png",
            // smartLabels: [],
          ),
        );
        selectedCategory = await database.getCategoryInstanceGivenName(
            row[assignedColumns["category"]!["setHeaderIndex"]]);
      }
    }
    categoryFk = selectedCategory.categoryPk;

    if (name != "") {
      // print("attempting to add " + name);
      await addAssociatedTitles(name, selectedCategory);
    }

    int walletFk = 0;
    if (assignedColumns["wallet"]!["setHeaderIndex"] == -1) {
      walletFk = appStateSettings["selectedWallet"];
    } else {
      try {
        walletFk = (await database.getWalletInstanceGivenName(
                row[assignedColumns["wallet"]!["setHeaderIndex"]]))
            .walletPk;
      } catch (e) {
        throw "Wallet not found! If you want to import to the current wallet, please select '~Current Wallet~'. Details: " +
            e.toString();
      }
    }

    DateTime dateCreated;
    try {
      dateCreated =
          DateTime.parse(row[assignedColumns["date"]!["setHeaderIndex"]]);
    } catch (e) {
      throw "Failed to parse time! Details: " + e.toString();
    }

    bool income = amount > 0;

    await database.createOrUpdateTransaction(
      Transaction(
        transactionPk: transactionPk,
        name: name,
        amount: amount,
        note: note,
        categoryFk: categoryFk,
        walletFk: walletFk,
        dateCreated: dateCreated,
        income: income,
        paid: true,
        skipPaid: false,
      ),
    );

    return;
  }

  Future<void> _importEntries(Map<String, Map<String, dynamic>> assignedColumns,
      List<List<String>> fileContents) async {
    try {
      for (int i = 0; i < fileContents.length; i++) {
        if (i == 0) {
          continue;
        }
        setState(() {
          currentPercent = i / fileContents.length * 100;
        });
        await Future.delayed(Duration(milliseconds: 0), () async {
          List<String> row = fileContents[i];
          await _importEntry(assignedColumns, row, i);
        });
      }
      widget.next();
    } catch (e) {
      openPopup(
        context,
        title: "There was an error importing the CSV",
        description: e.toString(),
        icon: Icons.error_rounded,
        onSubmitLabel: "OK",
        onSubmit: () {
          Navigator.of(context).pop();
          Navigator.of(context).pop();
        },
        barrierDismissible: false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ProgressBar(
      currentPercent: currentPercent,
      color: Colors.black,
    );
  }
}