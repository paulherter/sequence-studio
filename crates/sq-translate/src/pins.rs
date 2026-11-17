// Generated from the Hugging Face API (Xenova/opus-mt-*, commit-pinned): repo, commit, then file, size, sha256.
// The ONNX files are the int8 dynamic quantized exports (about 100 MB per direction).
/// One file: name in the repo, size, sha256.
pub(crate) type Pinned = (&'static str, u64, &'static str);
/// Repo, commit, files.
pub(crate) type RepoPin = (&'static str, &'static str, &'static [Pinned]);
pub(crate) const PINS: &[RepoPin] = &[
    (
        "en-de",
        "1ca130c44c4c5441ef16d48aae521a424ab644f7",
        &[
            (
                "onnx/encoder_model_quantized.onnx",
                49366942,
                "15834b45fabd2dfb8c6c029b3ca3e7289aeefd90ece798ce42bcf548d1bd3b8d",
            ),
            (
                "onnx/decoder_model_merged_quantized.onnx",
                56652404,
                "8b46a825964cdd182fe47cc780f0fb87d357eae1f47cf20aa63c1c09be5b510c",
            ),
            ("source.spm", 768489, "678f2a1177d8389f67b66299762dcc4fc567e89b07e212ba91b0c56daecf47ce"),
            ("vocab.json", 1389436, "d5acea957b265a78554999144459c5e391e0df525864edc8287bc090290baa44"),
            ("config.json", 1411, "517955ebf66cd6523f9982851dd41771b74fb2d9c00b4933ba2922ac7a63336f"),
        ],
    ),
    (
        "en-fr",
        "28726206f80896b90035bd99cccd5cc1e151f916",
        &[
            (
                "onnx/encoder_model_quantized.onnx",
                50090398,
                "0a81bdba62f53223740a8c6c6f58e716eba8ea1f92dfa569caf27ed5e3b6a0f7",
            ),
            (
                "onnx/decoder_model_merged_quantized.onnx",
                57381512,
                "333b244bce16023df04541c8cf9fd60aec9b0569da393c4b831d561897b0bda8",
            ),
            ("source.spm", 778395, "173e9f493a668fe396d599e28d414a201193094e6ffd7a4678e5aab0f6d3d838"),
            ("vocab.json", 1458196, "f2ba9c69ae20f96b8bd821239a9152be422394f980350b77907cffc183db5f2d"),
            ("config.json", 1411, "b522b73fcc86f77981349c1df2a2e041eed0dbcbea4acf2635019cf21d51ffc0"),
        ],
    ),
    (
        "en-es",
        "4b002a4c7edd54a7ced58877258b87f7efd3f892",
        &[
            (
                "onnx/encoder_model_quantized.onnx",
                52899742,
                "03434edd1147e6c49e22066e9dc5888235e99cc35a6711d1c4ea5b06455d5da9",
            ),
            (
                "onnx/decoder_model_merged_quantized.onnx",
                60212804,
                "58ee5ddd6e22d1693d8722b90c1486afb93700a4376cf28fd74175052ad530ae",
            ),
            ("source.spm", 801636, "4dd547c24816a335e7b0b2e63376a8f1b3cbfc671eda5ab808dd44fdadaa8791"),
            ("vocab.json", 1720044, "b074b4cca0036ade5a39ea97faabd534e1015482c480fc2cb02c6481983eb163"),
            ("config.json", 1468, "499eae1f97eeba63172fc884f92fd727ae803b7ceb79c0f653aa4b011152af2f"),
        ],
    ),
    (
        "en-it",
        "075406e3c8c2c30634d4a1bd8f00c21d9e162011",
        &[
            (
                "onnx/encoder_model_quantized.onnx",
                60597150,
                "b51c5110c7ba356ef01ee400d427afe162e657de1d7a2e9a40deedd811b49e6f",
            ),
            (
                "onnx/decoder_model_merged_quantized.onnx",
                67970348,
                "f9db146ed7665ea7d437dc4df564e3af5df923366de4d52aaf2c4b4e3e4ae4f1",
            ),
            ("source.spm", 789468, "2efff2c37e51842c2817a6770280979b5dd803cebbe2928e576d42a888f89537"),
            ("vocab.json", 2511647, "40c98ffc0013f2f09ed9127418131738ad9c2de4d8f7f52d52532332bb2bf78c"),
            ("config.json", 1376, "1cf40ab3aa16e8b6ea7c9766981de1da705a161564c0d5ad187c1e62e5c8ee85"),
        ],
    ),
    (
        "en-nl",
        "c3a0541231a7329b4492809fc2bd7ab7d2ceb0bc",
        &[
            (
                "onnx/encoder_model_quantized.onnx",
                53937565,
                "0febb990f8ca8ed9fd3e0017dfcb55ec5293999f20ead81d2bb4370e9e3120ff",
            ),
            (
                "onnx/decoder_model_merged_quantized.onnx",
                61258735,
                "5f8034fddc4cdcb6fa6c3b64a06e1cd9b1955c0c6dcd13e0e47610ab99ac4a99",
            ),
            ("source.spm", 789525, "d05781fde84b8793191528a7a176e1b17f96265388f602379ee6ae3139f59141"),
            ("vocab.json", 1794274, "b1fba91c620564d90848c5f77b03f13d17949790f8e7c7741e4a8ea13b8b0d91"),
            ("config.json", 1376, "3469caf791a6a038451e418d4254434087c94afc7d9676c03d38b9c64ce258c5"),
        ],
    ),
    (
        "en-ROMANCE",
        "9d2ba69ac80c8e8453c3d9a1e2323a0e7b8ca3cd",
        &[
            (
                "onnx/encoder_model_quantized.onnx",
                52899742,
                "b4ddfd9338ba3d7c6b9c2d1410ed94fb7e06741226918cef6148031101bbd019",
            ),
            (
                "onnx/decoder_model_merged_quantized.onnx",
                60212804,
                "b5f6d442da7fa69f9d500df90373d2fdca4f799c43696b41888353b5c3c8eb13",
            ),
            ("source.spm", 779155, "b1f89e7b05828846baf19109a61029a36838f1c4f3defc218e6aee0ee2787864"),
            ("vocab.json", 1587364, "d9c3b6b01d3a9c9403befa60fd17e4a50dc4929698e3d6b9c2e7f066a9d1f041"),
            ("config.json", 1508, "dc4f6f9ffbbf1196ff9e8329e5666fe190aef1b1c6806649d86b962b9bde292c"),
        ],
    ),
    (
        "de-en",
        "399dfd68706739fffd503f876093e455ae268a06",
        &[
            (
                "onnx/encoder_model_quantized.onnx",
                49366942,
                "4cedda8f8c89b72a42b3c6cd1e7a27f2de24457093e3bf80cb3e46829641fcd8",
            ),
            (
                "onnx/decoder_model_merged_quantized.onnx",
                56652404,
                "4712800584b2d77c2f9e620bf29523e2b20b62f65ade5011ee01780e2b0ea5d3",
            ),
            ("source.spm", 796845, "bbd1f495eea99c8e21ae086d9146e0fa7b096c3dfdd9ba07ab8b631889df5c9b"),
            ("vocab.json", 1389436, "d5acea957b265a78554999144459c5e391e0df525864edc8287bc090290baa44"),
            ("config.json", 1376, "6754743ec4754957d8552dad869d1314f3af6626b67446ec4cebe5e2fbaa0fc4"),
        ],
    ),
    (
        "fr-en",
        "6b166a182780e118c997879d0ad5be4b53671644",
        &[
            (
                "onnx/encoder_model_quantized.onnx",
                50090398,
                "e727cb26ac6bf816394c49671af69c9ae5798868fed1e40849872415dffc1772",
            ),
            (
                "onnx/decoder_model_merged_quantized.onnx",
                57381512,
                "73bc7ac8e29c42e6f212ebcc29a2991d3646a04aabb642c0036aa54b40e4e1a9",
            ),
            ("source.spm", 802397, "78d0e717c77053f1c4b856d8661d9cb87c64f083a35418c087b9146300e4f585"),
            ("vocab.json", 1458196, "f2ba9c69ae20f96b8bd821239a9152be422394f980350b77907cffc183db5f2d"),
            ("config.json", 1411, "6c2851f154d7b88c7767e4fdcf8a5694a36a456bfa6cbcde1b13fdbade3b56f6"),
        ],
    ),
    (
        "es-en",
        "eadfd7c658a9d8929ac3b8e996b68a68e2c7d480",
        &[
            (
                "onnx/encoder_model_quantized.onnx",
                52899742,
                "c01e70f8455efc350831aa2af7ed187b16829241f0018ba07d1ba643a391bc18",
            ),
            (
                "onnx/decoder_model_merged_quantized.onnx",
                60212804,
                "4cd91ab30240d295ce907b5100826031838c672005e57e524d711122d75605fa",
            ),
            ("source.spm", 825924, "e236ee6d866b635c0142114f8647f39831f9d92534aa2aad75c942f6a78ad0e3"),
            ("vocab.json", 1720044, "b074b4cca0036ade5a39ea97faabd534e1015482c480fc2cb02c6481983eb163"),
            ("config.json", 1433, "fab3a7f93185bc5aa7b419f6a1e6e74d98c8f2a506c94493d3019bf46da3478d"),
        ],
    ),
    (
        "it-en",
        "fd0b89b9c052adc1f2f64152f555aa17353728be",
        &[
            (
                "onnx/encoder_model_quantized.onnx",
                60773278,
                "a025d2d85c90da23880116b67175e43e71921d8d2bf446b9f1eacdc86015aa4c",
            ),
            (
                "onnx/decoder_model_merged_quantized.onnx",
                68147852,
                "aebc2789cd2ef8062fbda020bac90b61e68458ba98a4c43cea63c1d2310ba2b8",
            ),
            ("source.spm", 813709, "1bd307e2756991d470e4b40172147f7889b46a323b1a9a2150e66274825b1f21"),
            ("vocab.json", 2530593, "08e5b03ab20b2b9b85d41aed1b36dce2650afcb6e96274a06b7869b2e06884d5"),
            ("config.json", 1376, "4b82a23b7a91b213a934db70d0a33712a739fdd7c5686b02d89642d7dcfc7ac4"),
        ],
    ),
    (
        "nl-en",
        "82c42d95d1508037cbe7172d85fd4e940a2f3584",
        &[
            (
                "onnx/encoder_model_quantized.onnx",
                53937566,
                "7b8b1e9071bed8e2394e3bd2f65b952700b1dd1293d087141134c8bac018653b",
            ),
            (
                "onnx/decoder_model_merged_quantized.onnx",
                61258736,
                "ad4df9a08f16952c0d9ee06807f54d62fcd07a9109c2c0b8ea05a4422d7bf4d7",
            ),
            ("source.spm", 813866, "f538d23d4b30641cd97c608d2a83890d503aa1286a5560f19ef949404a786e94"),
            ("vocab.json", 1794274, "b1fba91c620564d90848c5f77b03f13d17949790f8e7c7741e4a8ea13b8b0d91"),
            ("config.json", 1376, "e03f36d5475954f1c09b08d0da68d6ea06a051e299a399e740554ed768d2a99c"),
        ],
    ),
    (
        "ROMANCE-en",
        "f60feaabe8bb435a5871e7702b25f53a01e770f8",
        &[
            (
                "onnx/encoder_model_quantized.onnx",
                52899741,
                "13750ba31ee80c88f6bbb28aa03320674c50394efb95f791d5c4f5c8894232bf",
            ),
            (
                "onnx/decoder_model_merged_quantized.onnx",
                60212803,
                "5c0d95a8072a463c747343cf25ac9b4a17e9a90e08131e7efab12691ca13c979",
            ),
            ("source.spm", 800087, "baeab21ec00d0b490382b82499ef0348235c5a8e75de28aec8290adf62b007c4"),
            ("vocab.json", 1590308, "32c8eeec099b448425a7da4e09ec10acbe424a733780c9bcec2062846f03e706"),
            ("config.json", 1361, "df1876a346b1852ef4590bc74c6e180eb2ba10193cf2bded24c31876f357d83c"),
        ],
    ),
];
