
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:provider/provider.dart';
import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'dart:convert';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  var initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
  var initializationSettingsIOS = DarwinInitializationSettings();
  var initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
    iOS: initializationSettingsIOS,
  );

  await NewsProvider.flutterLocalNotificationsPlugin.initialize(initializationSettings);
  runApp(
    ChangeNotifierProvider(
      create: (_) => NewsProviderManager(),
      child: const MyApp(),
    ),
  );

}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'News Tracker',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const MainScreen(),
    );
  }
}

class News {
  final String title;
  final String content;
  final String link;
  final DateTime date;

  News({
    required this.title,
    required this.content,
    required this.link,
    required this.date,
  });

  // Factory constructor to create a News instance from JSON
  factory News.fromJson(Map<String, dynamic> json) {
    return News(
      title: json['title'],
      content: json['content'],
      link: json['link'],
      date: DateTime.fromMillisecondsSinceEpoch(json['date']),
    );
  }
}

// Class is expanded too much.
class NewsProvider extends ChangeNotifier {
  List<News> _newsList = [];
  List<News> get newsList => _newsList;
  late final String serverUrl;
  String? _userId;
  int validation = 0;

  late WebSocketManager _webSocketManager;

  static FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
  FlutterLocalNotificationsPlugin();

  NewsProvider({required this.serverUrl}) {
    _userId = generateUserId(); // Generate or fetch the userId
    _webSocketManager = WebSocketManager(
      serverUrl: 'ws://$serverUrl:8080',
      userId: _userId.toString(),
      onNotificationReceived: _handleIncomingNotification,
    );

    // Set up notification tap handler
    flutterLocalNotificationsPlugin.initialize(
      InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
      onDidReceiveNotificationResponse: (response) async {
        await fetchNews(); // Fetch latest news
        String? title = response.payload;
        if (title != null) {
          navigateToNewsByTitle(title);
        }
      },
    );
  }

  void connectAfterValidation(){
    _webSocketManager.connect();
  }

  set newsList(List<News> value) {
    _newsList = value;
    notifyListeners();
  }

  Future<void> initData() async {
    try {
      if(validation == 1) {
        _webSocketManager.connect();
        await fetchNews();
      }
      notifyListeners();
    } catch (e) {
      print('Error fetching news: $e');
    }
  }

  @override
  void dispose() {
    validation = 0;
    _webSocketManager.disconnect();
    super.dispose();
  }

  // Handle incoming WebSocket notifications
  void _handleIncomingNotification(Map<String, dynamic> data) {
    try {
      data.forEach((key, value) {
        print('$key: $value');
      });
      if (data.containsKey('title')) {
        final title = data['title'];
        NewsProvider.showNotification(title, title); // Pass title as payload
      }
    } catch (e) {
      print('Error processing WebSocket notification: $e');
    }
  }

  // Fetch latest news and navigate to the clicked news by title
  void navigateToNewsByTitle(String title) {
    final news = _newsList.firstWhere(
          (item) => item.title == title,
      orElse: () => throw Exception('News not found'),
    );
    // Navigate to NewsDetailScreen (ensure this runs in a widget context)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Navigator.of(GlobalKey<NavigatorState>().currentContext!).push(
        MaterialPageRoute(
          builder: (context) => NewsDetailScreen(news: news),
        ),
      );
    });
  }

  Future<Map<String, dynamic>> registerOrLogin() async {
    print('registerLogin...');
    try {
      final uri = Uri.parse('http://$serverUrl:1337/registerOrLogin');
      final response = await http.post(uri, body: {'userId': _userId});

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        print(responseData['message']); // Print the server's response
        return {
          'success': responseData['success'] ?? false,
          'message': responseData['message'] ?? 'Unknown response',
        };
      } else {
        print('Failed to register.');
        return {
          'success': false,
          'message': 'Failed to register/login user. Status code: ${response.statusCode}',
        };
      }
    } catch (e) {
      print('error...');
      return {'success': false, 'message': 'Error: $e'};
    }
  }

  static Future<void> showNotification(
      String? title, String? payload) async {
    var android = const AndroidNotificationDetails(
      'channel_id',
      'channel_name',
      channelDescription: 'channel_description',
      priority: Priority.high,
      importance: Importance.max,
      icon: '@mipmap/ic_launcher',
    );
    var iOS = const DarwinNotificationDetails();
    var platform = NotificationDetails(android: android, iOS: iOS);

    await flutterLocalNotificationsPlugin.show(
      0,
      title,
      "You got latest news bro",
      platform,
      payload : payload,
    );

  }


  // Fetch news from the server
  Future<void> fetchNews() async {
    try {
      final uri = Uri.parse('http://$serverUrl:1337/mobileData');
      final response = await http.post(uri, body: {'userId': _userId});

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        _newsList.addAll(data.map((item) => News.fromJson(item)).toList());
        saveNewsToStorage();
        notifyListeners();
      } else {
        print('Failed to fetch news. Status code: ${response.statusCode}');
      }
    } catch (e) {
      print('Error fetching news: $e');
    }
  }


  static String? generateUserId() {
    // Use the uuid package to generate a UUID (Universally Unique Identifier)
    const uuid = Uuid();
    return uuid.v4();
  }

  Future<void> saveNewsToStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final newsJson = _newsList.map((news) => json.encode({
        'title': news.title,
        'content': news.content,
        'link': news.link,
        'date': news.date.millisecondsSinceEpoch,
      })).toList();
      await prefs.setStringList('news_${serverUrl}', newsJson);
    } catch (e) {
      print('Error saving news to storage: $e');
    }
  }

  Future<void> loadNewsFromStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final newsJson = prefs.getStringList('news_${serverUrl}') ?? [];
      _newsList = newsJson.map((jsonItem) {
        final item = json.decode(jsonItem);
        return News(
          title: item['title'],
          content: item['content'],
          link: item['link'],
          date: DateTime.fromMillisecondsSinceEpoch(item['date']),
        );
      }).toList();
      notifyListeners();
    } catch (e) {
      print('Error loading news from storage: $e');
    }
  }

}

class NewsListScreen extends StatelessWidget {
  final NewsProvider provider;

  const NewsListScreen({super.key, required this.provider});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: provider,
      child: Consumer<NewsProvider>(
        builder: (context, provider, child) {
          return Scaffold(
            appBar: AppBar(
              title: const Text('News List'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () async {
                    await provider.fetchNews(); // Refresh news data
                  },
                ),
              ],
            ),
            drawer: AppDrawer(currentProvider: provider),
            body: provider.newsList.isEmpty
                ? const Center(
              child: Text('No news available. Pull to refresh.'),
            )
                : ListView.builder(
              itemCount: provider.newsList.length,
              itemBuilder: (context, index) {
                final news = provider.newsList[index];
                return ListTile(
                  title: Text(news.title),
                  subtitle: Text('Published: ${news.date.toLocal()}'),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) =>
                            NewsDetailScreen(news: news),
                      ),
                    );
                  },
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class NewsDetailScreen extends StatelessWidget {
  final News news;

  const NewsDetailScreen({super.key, required this.news});

  // Method to open the URL in a web browser
  void _launchURL(String url) async {
    try {
      final uri = Uri.parse(url);

      if (await canLaunchUrl(uri)) {
        await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
      } else {
        throw 'Could not launch $url';
      }
    } catch (e) {
      print('Error launching URL: $e');
    }
  }



  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(news.title),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              news.title,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Text(
              news.content,
              style: const TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: () => _launchURL(news.link),
              child: Text(
                news.link,
                style: const TextStyle(
                  fontSize: 14,
                  color: Colors.blue,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Date: ${news.date.toLocal()}',
              style: const TextStyle(fontSize: 14, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  _MainScreenState createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  void _showAddProviderDialog(BuildContext context) {
    final serverUrlController = TextEditingController();

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Add New News Provider'),
          content: TextField(
            controller: serverUrlController,
            decoration: const InputDecoration(labelText: 'Server URL'),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                final newProvider =
                NewsProvider(serverUrl: serverUrlController.text);

                // Call register/login API and get the response
                final response = await newProvider.registerOrLogin();

                // Show response as an alert
                showDialog(
                  context: context,
                  builder: (BuildContext context) {
                    return AlertDialog(
                      title: Text(response['success'] ? 'Success' : 'Error'),
                      content: Text(response['message']),
                      actions: [
                        TextButton(
                          onPressed: () {
                            Navigator.of(context).pop();
                          },
                          child: const Text('OK'),
                        ),
                      ],
                    );
                  },
                );

                // If successful, add the provider
                if (response['success']) {
                  Provider.of<NewsProviderManager>(context, listen: false)
                      .addProvider(newProvider);
                }

                Navigator.of(context).pop();
              },
              child: const Text('Add'),
            ),
          ],
        );
      },
    );
  }


  void _confirmDeleteProvider(
      BuildContext context, NewsProviderManager manager, int index) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Delete Provider'),
          content: const Text('Are you sure you want to delete this provider?'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                manager.removeProvider(index); // Remove the provider
                Navigator.of(context).pop();
              },
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _loadInitialData() async {
    final manager = Provider.of<NewsProviderManager>(context, listen: false);
    await manager.loadProviders();
    setState(() {
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<NewsProviderManager>(
      builder: (context, manager, child) {
        if (_isLoading) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final newsProviders = manager.newsProviders;

        return Scaffold(
          appBar: AppBar(title: const Text('News Providers')),
          drawer: AppDrawer(
            currentProvider: newsProviders.isNotEmpty
                ? newsProviders.first
                : NewsProvider(serverUrl: 'localhost:1337/mobileData'),
          ),
          body: newsProviders.isEmpty
              ? const Center(child: Text('No news providers available.'))
              : ListView.builder(
            itemCount: newsProviders.length,
            itemBuilder: (context, index) {
              final provider = newsProviders[index];
              return ListTile(
                title: Text('Provider ${index + 1}'),
                subtitle: Text('URL: ${provider.serverUrl}'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete, color: Colors.red),
                  onPressed: () {
                    _confirmDeleteProvider(context, manager, index);
                  },
                ),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) =>
                          NewsListScreen(provider: provider),
                    ),
                  );
                },
              );
            },
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: () {
              _showAddProviderDialog(context);
            },
            child: const Icon(Icons.add),
          ),
        );
      },
    );
  }
}


class AppDrawer extends StatelessWidget {
  final NewsProvider currentProvider;

  const AppDrawer({super.key, required this.currentProvider});

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          const DrawerHeader(
            decoration: BoxDecoration(color: Colors.blue),
            child: Text(
              'Navigation',
              style: TextStyle(color: Colors.white, fontSize: 24),
            ),
          ),
          ListTile(
            title: const Text('Main Screen'),
            onTap: () {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (context) => const MainScreen()),
              );
            },
          ),
          const Divider(),
          const ListTile(title: Text('News Titles:')),
          ...currentProvider.newsList.map(
                (news) => ListTile(
              title: Text(news.title),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => NewsDetailScreen(news: news),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class NewsProviderManager extends ChangeNotifier {
  List<NewsProvider> _newsProviders = [];
  List<NewsProvider> get newsProviders => _newsProviders;

  NewsProviderManager() {
    loadProviders();
  }

  void addProvider(NewsProvider provider) {
    provider.validation = 1;
    provider.connectAfterValidation();
    _newsProviders.add(provider);
    saveProvidersToStorage(_newsProviders);
    notifyListeners();
  }

  void removeProvider(int index) {
    _newsProviders[index].dispose(); // Close WebSocket connection
    _newsProviders.removeAt(index);
    saveProvidersToStorage(_newsProviders);
    notifyListeners();
  }

  Future<void> loadProviders() async {
    _newsProviders = await loadProvidersFromStorage();
    for (var provider in _newsProviders) {
      await provider.loadNewsFromStorage();
      provider.initData(); // Ensure WebSocket reconnects
    }
    notifyListeners();
  }
}

Future<void> saveProvidersToStorage(List<NewsProvider> providers) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final providerJson = providers.map((provider) => provider.serverUrl).toList();
    await prefs.setStringList('providers', providerJson);
  } catch (e) {
    print('Error saving providers to storage: $e');
  }
}

Future<List<NewsProvider>> loadProvidersFromStorage() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final providerJson = prefs.getStringList('providers') ?? [];
    return providerJson.map((url) => NewsProvider(serverUrl: url)).toList();
  } catch (e) {
    print('Error loading providers from storage: $e');
    return [];
  }
}

class WebSocketManager {
  late WebSocketChannel? _channel;
  late String serverUrl;
  final String userId;

  int tried = 0;

  // Callback for handling incoming notifications
  Function(Map<String, dynamic>)? onNotificationReceived;

  WebSocketManager({
    required this.serverUrl,
    required this.userId,
    this.onNotificationReceived,
  });

  void connect() {
    _channel = WebSocketChannel.connect(Uri.parse(serverUrl));

    // Register the user after connecting
    _sendRegisterMessage();

    // Listen to the WebSocket stream
    _channel!.stream.listen(
          (message) {
        // Parse incoming notification
            final data = message is String ? jsonDecode(message) : message;
        if (onNotificationReceived != null) {
          if(data is Map<String, dynamic>){
            onNotificationReceived!(data);
          }else{

          }
        }
      },
      onError: (error) {
            tried++;
        print('WebSocket error: $error');
        reconnect();
      },
      onDone: (){
            tried++;
            print('WebSocket connection closed. Reconnecting...');
            reconnect();
      },
    );
  }

  void reconnect() {
    if(tried > 10){return;}
    if(tried > 5){
      Future.delayed(const Duration(seconds: 60),  connect);
      return;
    }
    Future.delayed(const Duration(seconds: 5), connect);
  }

  void disconnect() {
    if (_channel != null) {
      try {
        _channel!.sink.close();
        _channel = null;
      } catch (e) {
        print('Error while closing WebSocket: $e');
      }
    }
  }

  void sendMessage(Map<String, dynamic> message) {
    _channel!.sink.add(jsonEncode(message));
  }

  void _sendRegisterMessage() {
    sendMessage({
      'type': 'register',
      'userId': userId,
    });
  }
}
