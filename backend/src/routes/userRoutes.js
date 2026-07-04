const router = require('express').Router();
const { authMiddleware } = require('./authRoutes');
const {
  listUsers, getUser, updateMe, blockUser, unblockUser, blockStatus,
} = require('../controllers/usersController');

// Danh sách / hồ sơ user chỉ xem được khi đã đăng nhập
router.use(authMiddleware);

router.get('/',      listUsers);
router.patch('/me',  updateMe);   // phải đứng trước /:id

router.post('/:id/block',   blockUser);
router.delete('/:id/block', unblockUser);
router.get('/:id/blocked',  blockStatus);

router.get('/:id',   getUser);

module.exports = router;
