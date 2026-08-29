/// 会员播放设备管理数据（GET /x/vip/play_devices/list）
class VipDeviceData {
  List<PlayDevice>? devices;
  DeviceUser? user;
  List<PricePanel>? pricePanels;

  VipDeviceData({this.devices, this.user, this.pricePanels});

  factory VipDeviceData.fromJson(Map<String, dynamic> json) => VipDeviceData(
    devices: (json['devices'] as List?)
        ?.map((e) => PlayDevice.fromJson(e as Map<String, dynamic>))
        .toList(),
    user: json['user'] == null
        ? null
        : DeviceUser.fromJson(json['user'] as Map<String, dynamic>),
    pricePanels: (json['price_panels'] as List?)
        ?.map((e) => PricePanel.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}

/// 播放设备（status: 2=主设备 3=已被限制观看；play_status: 1=未播放 2=最近看过 3=播放中）
class PlayDevice {
  String? name;
  String? icon;
  int? status;
  int? playStatus;
  String? location;
  bool? isCurrentDevice;
  String? platform;
  String? mobiApp;
  String? buvid;
  String? device;
  String? model;
  String? brand;
  String? deviceName;

  PlayDevice({
    this.name,
    this.icon,
    this.status,
    this.playStatus,
    this.location,
    this.isCurrentDevice,
    this.platform,
    this.mobiApp,
    this.buvid,
    this.device,
    this.model,
    this.brand,
    this.deviceName,
  });

  factory PlayDevice.fromJson(Map<String, dynamic> json) => PlayDevice(
    name: json['name'] as String?,
    icon: json['icon'] as String?,
    status: json['status'] as int?,
    playStatus: json['play_status'] as int?,
    location: json['location'] as String?,
    isCurrentDevice: json['is_current_device'] as bool?,
    platform: json['platform'] as String?,
    mobiApp: json['mobi_app'] as String?,
    buvid: json['buvid'] as String?,
    device: json['device'] as String?,
    model: json['model'] as String?,
    brand: json['brand'] as String?,
    deviceName: json['deviceName'] as String?,
  );
}

/// 账号信息（设为主设备短信验证所需）
class DeviceUser {
  int? mid;
  String? phone;

  DeviceUser({this.mid, this.phone});

  factory DeviceUser.fromJson(Map<String, dynamic> json) => DeviceUser(
    mid: json['mid'] as int?,
    phone: json['phone'] as String?,
  );
}

class PricePanel {
  String? title;
  int? price;
  int? discountPrice;
  String? link;

  PricePanel({this.title, this.price, this.discountPrice, this.link});

  factory PricePanel.fromJson(Map<String, dynamic> json) => PricePanel(
    title: json['title'] as String?,
    price: json['price'] as int?,
    discountPrice: json['discount_price'] as int?,
    link: json['link'] as String?,
  );
}
